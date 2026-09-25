shader_type canvas_item;

uniform sampler2D gradient_texture : source_color;

uniform vec2 camera_center;
uniform vec2 texture_size;
uniform float world_to_texture = 0.1;
uniform float zoom = 1.0;

uniform float alpha = 1.0;

void fragment() {
    vec2 view_pos = (UV - vec2(0.5)) * texture_size;
    vec2 world_pos = camera_center + view_pos / zoom;

    vec2 sample_uv = vec2(0.5) + world_pos * world_to_texture / texture_size;
    if (sample_uv.x < 0.0 || sample_uv.x > 1.0 ||
        sample_uv.y < 0.0 || sample_uv.y > 1.0) {
        discard;
    }

    vec4 tex = texture(TEXTURE, sample_uv);
    float value = tex.r;
    vec3 gradient = texture(gradient_texture, vec2(value, 0.5)).rgb;

    //COLOR = vec4(gradient, tex.a);
    COLOR = vec4(gradient, alpha);
}