#[compute]
#version 450
layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;
shared uint prefix_sum_temp[256]; // adjust size to local_size_x*local_size_y
shared uint block_base;
const float EPSILON = 0.0001;

struct MyVec2 { vec2 v; };

// === Input/Output Buffers ===
layout(rgba32f, set = 0, binding = 0) uniform restrict image2D input_particles; // R=pos.x, G=pos.y, B=vel.x, A=vel.y
layout(rgba32f, set = 1, binding = 0) uniform restrict image2D output_particles;

// Image buffers with trail data - HDR Scalar value
layout(rgba32f, set = 0, binding = 1) uniform coherent image2D input_trail; // why use rgba32f ? could try r32f?
layout(rgba32f, set = 1, binding = 1) uniform coherent image2D output_trail; // why use rgba32f ? could try r32f?

// Per Agent Species/type index
layout(set = 0, binding = 2, std430) buffer InSpeciesBuffer { int data[]; }   in_species_buffer;

// === Species Interaction Matrix ===
// (Flattened as species_count x species_count float array)
layout(set = 0, binding = 3, std430) readonly buffer MatrixBuffer {
    float data[];
} interaction_matrix;

// === Spatial Hashing Buffers ===
// spatial hashing: per-cell counts
layout(set = 0, binding = 4, std430) buffer CellCountBuffer {
    uint cell_counts[]; // length = num_cells
} cell_count_buffer;

// spatial hashing: per-cell offsets
layout(set = 0, binding = 5, std430) buffer CellOffsetBuffer {
    uint cell_offsets[]; // length = num_cells
} cell_offset_buffer;

// spatial hashing: sorted indices: list of agent ids grouped by cell
layout(set = 0, binding = 6, std430) buffer SortedIndexBuffer {
    uint sorted_indices[]; // length = agents_count
} sorted_index_buffer;

// spatial hashing: agent cells
layout(set = 0, binding = 7, std430) buffer AgentCellBuffer {
    uint data[];  // length = agents_count
} agent_cell_buffer;

// spatial hashing: cursor
layout(set = 0, binding = 8, std430) buffer CursorBuffer {
    uint data[];  // length = num_cells
} cursor_buffer;

// === Parameters ===
layout(push_constant, std430) uniform Params {

    float run_mode;             // determine which logic to run on GPU
    float dt;                   // Timestep
	float compute_texture_size; // Size of the data texture

	float mix_t;         		// Mix Boids with PLife
    float agents_count;         // Total agent count
    float species_count;        // Number of species

	float boid_vision_radius;   // Neighbor radius for flocking
    float species_interaction_radius; // Range of inter-species forces
	
	float alignment_force;      // Align with nearby velocities
    float cohesion_force;       // Pull toward neighbor center
    float separation_force;     // Push away when too close
	
    float movement_randomness;  // Random motion component
    float movement_scaling;     // Global motion multiplier	
    float force_softening;            // Avoids infinite forces at zero dist
    float center_attraction;          // Pull toward scene center
    float drag;                 // Velocity damping
    float min_speed;            // Clamp lower speed
    float max_speed;            // Clamp upper speed
    float max_force;            // Limit total applied force

    float sensor_distance;		// for slime mold behavior - 3 sensors
    float sensor_angle;			// for slime mold behavior - from forward facing
	float sensor_strength;		// for slime mold behavior - how strong is the slime steering?
    float deposit_amount;		// for slime mold behavior - deposit trail
	
    float diffusion_rate;		// for slime mold behavior - how much diffusion of trail
    float evaporation_rate;		// for slime mold behavior - how much evaporation of trail

    float cell_size;        // hashing cell size
    float cells_per_row;    // hashing cells per row

    float image_size;           // Render target dimension
    float world_size_mult;       // Scales worlds for flocking	
} params;

// Clamp vector magnitude
vec2 limit(vec2 v, float max_val) {
    float mag = length(v);
    if (mag > max_val)
        return normalize(v) * max_val;
    return v;
}

// Safe normalize to avoid NaN on zero-length vectors
vec2 safe_normalize(vec2 v) {
    float len = length(v);
    return (len > 0.0001) ? v / len : vec2(0.0);
}

// Random direction based on integer ID
vec2 random_dir(uint id, float scale) {
    uint seed = id * 1664525u + 1013904223u;
    float ang = float(seed % 6283u) * 0.001f;
    return vec2(cos(ang), sin(ang)) * scale;
}

// Random value - cheap hash method
//float random_value(uint id)
//{
//   uint seed = id * 1664525u + 1013904223u;
//   return float(seed & 0x00FFFFFFu) / float(0x01000000u);
//}

// Toroidal distance difference (wrap-around world)
vec2 toroidal_diff(vec2 a, vec2 b, vec2 world_size) {
    vec2 d = b - a;
    d -= world_size * round(d / world_size);
    return d;
}

// Apply wrapping border
void apply_border(inout vec2 pos, inout vec2 vel) {
    float world_size = params.image_size * params.world_size_mult;
    float half_size = world_size * 0.5;
    if (pos.x < -half_size) pos.x += world_size;
    if (pos.x >  half_size) pos.x -= world_size;
    if (pos.y < -half_size) pos.y += world_size;
    if (pos.y >  half_size) pos.y -= world_size;
}

vec2 wrap_position(vec2 p)
{
    float world_size = params.image_size * params.world_size_mult;
	
    float h = world_size * 0.5;

    if (p.x < -h) p.x += world_size;
    if (p.x >= h) p.x -= world_size;

    if (p.y < -h) p.y += world_size;
    if (p.y >= h) p.y -= world_size;

    return p;
}
float sampleTrail(vec2 worldPos)
{
    float world_size = params.image_size * params.world_size_mult;
    worldPos = wrap_position(worldPos);
    vec2 uv = (worldPos / world_size) + 0.5;
    ivec2 size = imageSize(input_trail);
    ivec2 pixel = ivec2(uv * vec2(size));
    pixel = clamp(pixel, ivec2(0), size - 1);
    return imageLoad(input_trail, pixel).r;
}

float sense(vec2 pos, float heading, float offsetAngle)
{
    float ang = heading + offsetAngle;
    vec2 dir = vec2(
        cos(ang),
        sin(ang)
    );
    vec2 sensorPos = pos + dir * params.sensor_distance;
    return sampleTrail(sensorPos);
}

// Apply softened and capped force
float apply_force(float f, float dist, float softening, float max_force) {
    float softened_dist = sqrt(dist * dist + softening * softening);
    float force_mag = f / softened_dist;
    return clamp(force_mag, -max_force, max_force);
}

vec2 sense_and_adjust_to_field()
{
    ivec2 uv = ivec2(gl_GlobalInvocationID.xy);

    int id = uv.y * int(params.compute_texture_size) + uv.x;

    if (id >= int(params.agents_count))
        return vec2(0.0);

    vec4 particle = imageLoad(input_particles, uv);

    vec2 pos = particle.xy;
    vec2 vel = particle.ba;

    float speed = length(vel);

    if (speed <= EPSILON)
        return vec2(0.0);

    vec2 current_dir = vel / speed;
    float heading = atan(current_dir.y, current_dir.x);

    float left = sense(pos, heading, params.sensor_angle);
    float center = sense(pos, heading, 0.0);
    float right = sense(pos, heading, -params.sensor_angle);

    vec2 desired_dir = current_dir;

    if (center >= left && center >= right)
    {
        desired_dir = current_dir;
		// note - consider using a random left or right dir, instead of straight forward
    }
    else if (left > right)
    {
        desired_dir = vec2(
            cos(heading + params.sensor_angle),
            sin(heading + params.sensor_angle)
        );
    }
    else
    {
        desired_dir = vec2(
            cos(heading - params.sensor_angle),
            sin(heading - params.sensor_angle)
        );
    }

    return (desired_dir - current_dir);
}

void deposit_to_field()
{
    ivec2 uv = ivec2(gl_GlobalInvocationID.xy);

    int id = uv.y * int(params.compute_texture_size) + uv.x;

    if (id >= int(params.agents_count))
        return;

    vec4 particle = imageLoad(input_particles, uv);
    vec2 pos = particle.xy;

    float world_size =
        params.image_size * params.world_size_mult;

    // Convert world position to wrapped [0,1] coordinates.
    vec2 wrapped_pos = wrap_position(pos);

    vec2 trail_pos =
        (wrapped_pos + world_size * 0.5) / world_size;

    ivec2 trail_size = imageSize(input_trail);

    ivec2 trail_uv =
        ivec2(trail_pos * vec2(trail_size));

    // Safety clamp.
    trail_uv = clamp(
        trail_uv,
        ivec2(0),
        trail_size - 1
    );

    float trail =
        imageLoad(input_trail, trail_uv).r;

    trail += params.deposit_amount;
    //trail += params.deposit_amount * params.dt;;

	// we lose some deposits here due to lack of atomics - maybe fix later
    imageStore(
        input_trail,
        trail_uv,
        vec4(trail, trail, trail, 1.0)
    );
}

// Main particle simulation logic (using spatial grid)
void run_sim_particles() {
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	int id = int(uv.y * params.compute_texture_size + uv.x);

	if (id >= params.agents_count || uv.x >= params.compute_texture_size || uv.y >= params.compute_texture_size) {
		return;
	}
	vec4 pixel = imageLoad(input_particles, uv);

    vec2 pos = pixel.rg;
    vec2 vel = pixel.ba;
    int species = in_species_buffer.data[id];

    // World and accumulators
    float world_size_d = params.image_size * params.world_size_mult;
    vec2 world_size = vec2(world_size_d);

    vec2 align = vec2(0.0);
    vec2 coh   = vec2(0.0);
    vec2 sep   = vec2(0.0);
    vec2 interact = vec2(0.0);
    int neighbor_count = 0;

    // Compute world-to-grid conversion
    float world_size_f = params.image_size * params.world_size_mult;
    float half_world = 0.5 * world_size_f;
    float cs = params.cell_size;
    int cpr = int(params.cells_per_row);

    // compute this agent's cell coords (wrap/toroidal)
    vec2 pos_wrapped = pos + vec2(half_world);
    pos_wrapped = mod(pos_wrapped + world_size_f, world_size_f);
    int cx = int(floor(pos_wrapped.x / cs)) % cpr;
    int cy = int(floor(pos_wrapped.y / cs)) % cpr;

    // iterate over neighbor cells (3x3)
    for (int dx = -1; dx <= 1; ++dx) {
        for (int dy = -1; dy <= 1; ++dy) {
            int ncx = (cx + dx) % cpr;
            int ncy = (cy + dy) % cpr;
            if (ncx < 0) ncx += cpr;
            if (ncy < 0) ncy += cpr;
            uint cell_index = uint(ncy * cpr + ncx);

            uint start = cell_offset_buffer.cell_offsets[cell_index];
            uint end   = start + cell_count_buffer.cell_counts[cell_index];
			
            for (uint k = start; k < end; ++k) {
                uint other = sorted_index_buffer.sorted_indices[k];
                if (other == id) continue;
				
				ivec2 other_uv = ivec2(other % int(params.compute_texture_size), other / params.compute_texture_size);
				vec4 other_pixel = imageLoad(input_particles, other_uv);
				
                vec2 other_pos = other_pixel.rg;
				vec2 other_vel = other_pixel.ba;
				int other_species = in_species_buffer.data[other];

                vec2 diff = toroidal_diff(pos, other_pos, vec2(world_size_f));
                float dist = length(diff);
                //if (dist < 0.0001) continue;
                if (dist < 0.0001) dist = 0.0001;

                // boid behavior
                if (dist < params.boid_vision_radius) {
                    neighbor_count++;
                    //align += in_vel_buffer.data[i].v;
					align += other_vel;
                    coh   += pos + diff;
                    sep  -= diff / (dist * dist);
                }

                // species interactions
                if (dist < params.species_interaction_radius) {
                    //int other_species = in_species_buffer.data[i];
                    float f = interaction_matrix.data[
                        species * uint(params.species_count) + other_species
                    ];
                    vec2 dir = diff / dist;
                    interact += dir * apply_force(f, dist, params.force_softening, params.max_force);
                }
            }
        }
    }

   // === Finalize BOIDS averages ===
    vec2 boid_force = vec2(0.0);
    if (neighbor_count > 0) {
        align = safe_normalize(align / neighbor_count) * params.alignment_force;
        coh   = safe_normalize((coh / neighbor_count) - pos) * params.cohesion_force;
        sep   = safe_normalize(sep) * params.separation_force;
        boid_force = align + coh + sep;
    }

    // === Combine BOIDS + PLife ===
    vec2 f_boid = boid_force;
    vec2 f_plife = interact;
    vec2 accel = mix(f_boid, f_plife, params.mix_t);

	// === SLIME MOLD ===
	vec2 f_trail = sense_and_adjust_to_field();	
	//accel += f_trail;
	//accel = mix(accel, f_trail, 0.5);
	accel = mix(accel, f_trail, params.sensor_strength);
	
    // Center pull
    if (params.center_attraction > 0.0001) {
        vec2 dir_to_center = safe_normalize(-pos);
        accel += dir_to_center * params.center_attraction;
    }

    // Add small random drift
    accel += random_dir(id, params.movement_randomness);
    accel = limit(accel, params.max_force);
	
	// Global accel scaling
	accel *= params.movement_scaling;

    // Clamp speed
	float speed = length(vel);
    if (speed < params.min_speed && speed > 0.0001)
        vel = normalize(vel) * params.min_speed;
    if (speed > params.max_speed)
        vel = normalize(vel) * params.max_speed;

	// Integrate
	vel += accel * params.dt;
	vel *= params.drag; // optional damping

    pos += vel * params.dt;
    apply_border(pos, vel);

    // === Particle Output ===
	imageStore(output_particles, uv, vec4(pos, vel));
	
	// === FIELD Output ===
	deposit_to_field();
}

void run_sim_field() {
	// diffusion and evap

    ivec2 p = ivec2(gl_GlobalInvocationID.xy);
    ivec2 size = imageSize(input_trail);
    if(any(greaterThanEqual(p,size)))
        return;

	/*
	// WORKING EXAMPLE - RAW DATA AS RGB
	float trail = imageLoad(input_trail, p).r * 10.0;
	trail = 0.5; // hardcode debug
    imageStore(output_trail,
               p,
               vec4(trail,0.0,0.0,1.0));
	*/

	float sum = 0.0;
	for(int y=-1;y<=1;y++)
		for(int x=-1;x<=1;x++)
		{
			ivec2 n = p + ivec2(x,y);

			n.x = (n.x + size.x) % size.x;
			n.y = (n.y + size.y) % size.y;

			sum += imageLoad(input_trail,n).r;
		}

	float diffusion = clamp(params.diffusion_rate, 0.0, 1.0);
	float evaporation = clamp(params.evaporation_rate, 0.0, 1.0);

    float trail = mix(imageLoad(input_trail,p).r,
		sum/9.0,
		diffusion);

    trail *= (1.0 - evaporation);
	// trail *= 10.0; // debug brighter
	
	// === FIELD Output ===
    imageStore(output_trail,
               p,
               vec4(trail,trail,trail,1.0));
}

void count_cells() {
	ivec2 uv = ivec2(gl_GlobalInvocationID.xy);
	int id = int(uv.y * params.compute_texture_size + uv.x);
	
	if (id >= params.agents_count || uv.x >= params.compute_texture_size || uv.y >= params.compute_texture_size) {
		return;
	}

	vec4 pixel = imageLoad(input_particles, uv);
	
	vec2 p = pixel.rg;
	
    float half_size = params.image_size * params.world_size_mult * 0.5; // matches world_size calc
    float rx = mod(p.x + half_size + params.image_size * params.world_size_mult, params.image_size * params.world_size_mult);
    float ry = mod(p.y + half_size + params.image_size * params.world_size_mult, params.image_size * params.world_size_mult);
    
    int cx = int(floor(rx / params.cell_size)) % int(params.cells_per_row);
    int cy = int(floor(ry / params.cell_size)) % int(params.cells_per_row);
    uint cell = uint(cy * int(params.cells_per_row) + cx);

    agent_cell_buffer.data[id] = cell; // buffer for agent -> cell mapping

    atomicAdd(cell_count_buffer.cell_counts[cell], 1u); // increment per-cell count
}

void prefix_sum() {
    const uint L = gl_WorkGroupSize.x * gl_WorkGroupSize.y; // 256u; // adjust size to local_size_x*local_size_y
    uint tid =
        gl_LocalInvocationID.y * gl_WorkGroupSize.x +
        gl_LocalInvocationID.x;
    uint group_id = gl_WorkGroupID.x;
    uint num_cells = uint(params.cells_per_row) * uint(params.cells_per_row);

    if (group_id == 0u && tid == 0u) cursor_buffer.data[0] = 0u;
    barrier();

    uint val = 0u;
    uint index = group_id * L + tid;
    if (index < num_cells) val = cell_count_buffer.cell_counts[index];
    prefix_sum_temp[tid] = val;
    barrier();

    for (uint offset = 1u; offset < L; offset <<= 1u) {
        uint step = offset << 1u;
        uint ix = (tid + 1u) * step - 1u;
        if (ix < L) prefix_sum_temp[ix] += prefix_sum_temp[ix - offset];
        barrier();
    }

    uint block_total = prefix_sum_temp[L - 1u];
    if (tid == 0u) prefix_sum_temp[L - 1u] = 0u;
    barrier();

    for (uint offset = L >> 1u; offset >= 1u; offset >>= 1u) {
        uint step = offset << 1u;
        uint ix = (tid + 1u) * step - 1u;
        if (ix < L) {
            uint t = prefix_sum_temp[ix - offset];
            prefix_sum_temp[ix - offset] = prefix_sum_temp[ix];
            prefix_sum_temp[ix] += t;
        }
        barrier();
        if (offset == 1u) break;
    }

	if (tid == 0u) block_base = atomicAdd(cursor_buffer.data[0], block_total);
	barrier();
	uint base = block_base;

    if (index < num_cells) {
        uint offset_for_cell = base + prefix_sum_temp[tid];
        cell_offset_buffer.cell_offsets[index] = offset_for_cell;
        cursor_buffer.data[index] = offset_for_cell;
    }
}

void scatter_sorted_indices() {
	uint width = gl_NumWorkGroups.x * gl_WorkGroupSize.x;
    uint id = gl_GlobalInvocationID.y * width + gl_GlobalInvocationID.x;
	if (id >= uint(params.agents_count)) return;

    uint cell = agent_cell_buffer.data[id]; // agent_cell_buffer
    uint pos = atomicAdd(cursor_buffer.data[cell], 1u); // cursor_buffer
    sorted_index_buffer.sorted_indices[pos] = id; // write to final sorted indices
}

void main() {
	// ---- GPU processing modes ----
    if (params.run_mode == 0 && params.dt > 0.0) {
        run_sim_particles();
    } else if (params.run_mode == 1 && params.dt > 0.0) {
        run_sim_field();

	// ---- GPU preprocessing modes ----
    } else if (params.run_mode == 10 && params.dt > 0.0) {  // COUNT CELLS
        count_cells();
    } else if (params.run_mode == 11 && params.dt > 0.0) {  // PREFIX SUM
        prefix_sum();
    } else if (params.run_mode == 12 && params.dt > 0.0) {  // SCATTER
        scatter_sorted_indices();
    }
}