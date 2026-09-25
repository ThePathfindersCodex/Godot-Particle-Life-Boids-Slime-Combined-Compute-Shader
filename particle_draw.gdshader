shader_type canvas_item;
uniform sampler2D alpha_tex : filter_linear, repeat_disable;
uniform sampler2D particle_buffer : filter_nearest, repeat_disable;
uniform sampler2D gradient_texture : filter_linear, repeat_disable, source_color;
uniform int compute_texture_size;
uniform vec2 viewport_size;
uniform int species_count = 0;
uniform vec2 camera_center;
uniform float zoom;
varying flat int v_instance_id;
varying flat int v_species_id;

// NOTE: this shader does not currently support the TRIANGLE particle 
// shape because it does not rotate the particle towards its heading. 
// Check the Boids sim repository if you want to grab the code used 
// to auto-orient the particles and draw them as TRIANGLES
//		SEE: https://github.com/ThePathfindersCodex/Godot-Boids-Compute-Shader/blob/main/particle_draw.gdshader

void vertex() {
	int id = INSTANCE_ID;
	v_instance_id = id;
	v_species_id = int(INSTANCE_CUSTOM.r);
	
	ivec2 texel = ivec2(id % compute_texture_size,
						id / compute_texture_size);
	vec4 data = texelFetch(particle_buffer, texel, 0);
	vec2 pos = data.rg;
	//vec2 vel = data.ba;

	// transform pos
	vec2 world_pos = pos;
	vec2 view_pos = (world_pos - camera_center) * zoom;
	vec2 screen_center = viewport_size * 0.5;

	float radius = 20.0 * zoom;
	vec2 local = VERTEX;
	local *= radius;

	VERTEX = view_pos + screen_center + local;
}

vec3 species_color_dynamic(int species) {
    // Map species index to 0..1 range
    float t = float(species) / max(float(species_count - 1), 1.0);
	return texture(gradient_texture, vec2(t, 1.0)).rgb;
}

void fragment() {
	// Compute color from particle species type
	vec3 rgb = species_color_dynamic(v_species_id);
	vec4 color = vec4(rgb, 1.0);
	float alpha = texture(alpha_tex, UV).a;
	if(alpha < 0.001) discard;
	COLOR = vec4(color.rgb, color.a * alpha);
}