#include <metal_stdlib>
using namespace metal;

constant float PI = 3.14159265358979323846f;
constant float GOLDEN_ANGLE = 2.3999631f;
constant float PHOTOMETRIC_CODES[9] = {0.0f, 0.05f, 0.10f, 0.18f, 0.25f, 0.50f, 0.75f, 0.90f, 1.0f};

struct SpatialParams {
    uint4 raster;       // full width, full height, origin x, origin y
    uint4 window;       // width, height, aperture samples, signal kind
    uint4 signal_meta;  // width, height, placement, procedural pattern
    uint4 panel_meta;   // native width, native height, stripe layout, environment pattern
    float4 camera_position_focal;
    float4 camera_right_sensor_width;
    float4 camera_up_sensor_height;
    float4 camera_forward_focus;
    float4 camera_limits; // f-stop, near, far, unused
    float4 lens_shift_radial01;
    float4 lens_radial2_tangential;
    float4 lens_longitudinal;
    float4 lens_lateral;
    float4 lens_transmission_vignette;
    float4 lens_softness;
    float4 screen_translation;
    float4 screen_quaternion;
    float4 panel_geometry; // active width, active height, black matrix, gamma
    float4 panel_levels_angular_r; // black, white, angular r, angular g
    float4 panel_angular_b;
    float4 panel_matrix_0;
    float4 panel_matrix_1;
    float4 panel_matrix_2;
    float4 cover_geometry; // strength, thickness mm, ior, AR efficiency
    float4 cover_absorption_roughness; // absorption rgb, roughness
    float4 cover_haze;
    float4 environment_ambient_strength; // ambient rgb, strength
    float4 environment_key_radius; // key rgb, angular radius radians
    float4 environment_direction; // key direction xyz, environment rotation radians
    float4 procedural_time;
    float4 pipeline_strengths; // panel, lens, reserved sensor, reserved
};

struct RayHit {
    float2 uv;
    float cosine;
    float3 reflection_direction;
    bool valid;
};

inline float3 quaternion_rotate(float4 quaternion, float3 value) {
    float3 t = 2.0f * cross(quaternion.xyz, value);
    return value + quaternion.w * t + cross(quaternion.xyz, t);
}

inline float3 screen_to_local_vector(constant SpatialParams& p, float3 value) {
    float4 inverse = float4(-p.screen_quaternion.xyz, p.screen_quaternion.w);
    return quaternion_rotate(inverse, value);
}

inline float3 screen_to_local_point(constant SpatialParams& p, float3 value) {
    return screen_to_local_vector(p, value - p.screen_translation.xyz);
}

inline float2 distort_point(float2 point, constant SpatialParams& p) {
    float radius2 = dot(point, point);
    float radial = 1.0f + p.lens_shift_radial01.z * radius2
        + p.lens_shift_radial01.w * radius2 * radius2
        + p.lens_radial2_tangential.x * radius2 * radius2 * radius2;
    float p1 = p.lens_radial2_tangential.y;
    float p2 = p.lens_radial2_tangential.z;
    return float2(
        point.x * radial + 2.0f * p1 * point.x * point.y + p2 * (radius2 + 2.0f * point.x * point.x),
        point.y * radial + p1 * (radius2 + 2.0f * point.y * point.y) + 2.0f * p2 * point.x * point.y
    );
}

inline bool inverse_distortion(float2 observed, constant SpatialParams& p, thread float2& ideal) {
    ideal = observed;
    constexpr float epsilon = 1.0e-4f;
    for (uint iteration = 0; iteration < 12; ++iteration) {
        float2 projected = distort_point(ideal, p);
        float2 residual = observed - projected;
        if (max(abs(residual.x), abs(residual.y)) < 1.0e-6f) return true;
        float2 dx = distort_point(ideal + float2(epsilon, 0.0f), p);
        float2 dy = distort_point(ideal + float2(0.0f, epsilon), p);
        float j00 = (dx.x - projected.x) / epsilon;
        float j10 = (dx.y - projected.y) / epsilon;
        float j01 = (dy.x - projected.x) / epsilon;
        float j11 = (dy.y - projected.y) / epsilon;
        float determinant = j00 * j11 - j01 * j10;
        if (!isfinite(determinant) || determinant <= 1.0e-8f) return false;
        ideal += float2(j11 * residual.x - j01 * residual.y,
                        -j10 * residual.x + j00 * residual.y) / determinant;
        if (!all(isfinite(ideal))) return false;
    }
    float2 residual = distort_point(ideal, p) - observed;
    return max(abs(residual.x), abs(residual.y)) < 1.0e-5f;
}

inline float radical_inverse(uint value) {
    return float(reverse_bits(value)) * (1.0f / 4294967296.0f);
}

inline float2 aperture_sample(uint index) {
    float radius = sqrt(radical_inverse(index + 1));
    float angle = float(index) * GOLDEN_ANGLE;
    return radius * float2(cos(angle), sin(angle));
}

inline float3 irradiance_weight(float2 ideal, constant SpatialParams& p) {
    float aperture = (PI * 0.25f) / (p.camera_limits.x * p.camera_limits.x);
    float3 result;
    for (uint channel = 0; channel < 3; ++channel) {
        float scale = p.lens_lateral[channel];
        float tangent_x = ideal.x * scale * p.camera_right_sensor_width.w
            / (2.0f * p.camera_position_focal.w);
        float tangent_y = ideal.y * scale * p.camera_up_sensor_height.w
            / (2.0f * p.camera_position_focal.w);
        float cosine = rsqrt(1.0f + tangent_x * tangent_x + tangent_y * tangent_y);
        float natural = cosine * cosine * cosine * cosine;
        float vignette = 1.0f + (natural - 1.0f) * p.lens_transmission_vignette.w;
        result[channel] = aperture * vignette * p.lens_transmission_vignette[channel];
    }
    return result;
}

inline RayHit trace_ray(float2 ideal_sensor, float2 lens_sample, uint channel,
                        constant SpatialParams& p) {
    RayHit miss;
    miss.uv = 0.0f; miss.cosine = 0.0f; miss.reflection_direction = 0.0f; miss.valid = false;
    float2 ideal = ideal_sensor * p.lens_lateral[channel];
    float3 pinhole = normalize(p.camera_forward_focus.xyz
        + p.camera_right_sensor_width.xyz * (ideal.x * p.camera_right_sensor_width.w
            / (2.0f * p.camera_position_focal.w))
        + p.camera_up_sensor_height.xyz * (ideal.y * p.camera_up_sensor_height.w
            / (2.0f * p.camera_position_focal.w)));
    float channel_focus = p.camera_forward_focus.w + p.lens_longitudinal[channel];
    float focus_scale = channel_focus / dot(pinhole, p.camera_forward_focus.xyz);
    float3 focus_point = p.camera_position_focal.xyz + pinhole * focus_scale;
    float aperture_radius = p.camera_position_focal.w * 0.001f / (2.0f * p.camera_limits.x);
    float3 lens_origin = p.camera_position_focal.xyz
        + p.camera_right_sensor_width.xyz * (lens_sample.x * aperture_radius)
        + p.camera_up_sensor_height.xyz * (lens_sample.y * aperture_radius);
    float3 ray = normalize(focus_point - lens_origin);
    float3 local_origin = screen_to_local_point(p, lens_origin);
    float3 local_ray = screen_to_local_vector(p, ray);
    if (abs(local_ray.z) < 1.0e-8f) return miss;
    float distance = -local_origin.z / local_ray.z;
    if (distance <= 0.0f) return miss;
    float3 local_point = local_origin + local_ray * distance;
    float3 world_point = p.screen_translation.xyz + quaternion_rotate(p.screen_quaternion, local_point);
    float depth = dot(world_point - p.camera_position_focal.xyz, p.camera_forward_focus.xyz);
    if (depth < p.camera_limits.y || depth > p.camera_limits.z) return miss;
    RayHit hit;
    hit.uv = float2(local_point.x / p.panel_geometry.x + 0.5f,
                    0.5f - local_point.y / p.panel_geometry.y);
    hit.cosine = clamp(-local_ray.z, 0.0f, 1.0f);
    hit.reflection_direction = float3(local_ray.x, local_ray.y, -local_ray.z);
    hit.valid = true;
    return hit;
}

inline float cover_interface(float view_cosine, constant SpatialParams& p, thread float& cosine_t) {
    float cosine_i = clamp(view_cosine, 0.0f, 1.0f);
    float eta = p.cover_geometry.z;
    float sine_t2 = (1.0f - cosine_i * cosine_i) / (eta * eta);
    cosine_t = sqrt(max(0.0f, 1.0f - sine_t2));
    if (eta == 1.0f || p.cover_geometry.w == 1.0f) return 0.0f;
    float rs = (cosine_i - eta * cosine_t) / max(1.0e-8f, cosine_i + eta * cosine_t);
    float rp = (eta * cosine_i - cosine_t) / max(1.0e-8f, eta * cosine_i + cosine_t);
    float bare = 0.5f * (rs * rs + rp * rp);
    return clamp(bare * (1.0f - p.cover_geometry.w) * p.cover_geometry.x, 0.0f, 0.98f);
}

inline float3 cover_transmission(float cosine, constant SpatialParams& p) {
    float cosine_t;
    float reflection = cover_interface(cosine, p, cosine_t);
    float absorption_scale = p.cover_geometry.y / max(cosine_t, 0.01f) * p.cover_geometry.x;
    float haze_loss = clamp(p.cover_haze.x * p.cover_geometry.x, 0.0f, 0.95f);
    return (1.0f - reflection) * exp(-p.cover_absorption_roughness.xyz * absorption_scale)
        * (1.0f - haze_loss);
}

inline float2 transmitted_uv(RayHit hit, constant SpatialParams& p) {
    if (p.cover_geometry.x == 0.0f || p.cover_geometry.z == 1.0f) return hit.uv;
    float3 direction = normalize(hit.reflection_direction);
    float cosine_i = max(abs(direction.z), 1.0e-4f);
    float eta = p.cover_geometry.z;
    float cosine_t = max(sqrt(max(0.0f, 1.0f - (1.0f - cosine_i * cosine_i) / (eta * eta))), 1.0e-4f);
    float thickness = p.cover_geometry.y * 0.001f * p.cover_geometry.x;
    float tangent_scale = thickness * (1.0f / (eta * cosine_t) - 1.0f / cosine_i);
    float2 offset = direction.xy * tangent_scale;
    return hit.uv + float2(offset.x / p.panel_geometry.x, -offset.y / p.panel_geometry.y);
}

inline float3 environment_radiance(float3 direction, constant SpatialParams& p) {
    direction = normalize(direction);
    float rotation_sine = sin(p.environment_direction.w);
    float rotation_cosine = cos(p.environment_direction.w);
    direction = float3(
        direction.x * rotation_cosine + direction.z * rotation_sine,
        direction.y,
        -direction.x * rotation_sine + direction.z * rotation_cosine
    );
    float alignment = clamp(dot(direction, p.environment_direction.xyz), -1.0f, 1.0f);
    float edge = cos(p.environment_key_radius.w);
    float softness = 0.005f + p.cover_absorption_roughness.w * 0.35f;
    float key_amount = smoothstep(edge - softness, edge + softness, alignment);
    float pattern_amount = 0.0f;
    if (p.panel_meta.w == 1) {
        float large_x = 1.0f - smoothstep(0.30f - softness, 0.30f + softness, abs(direction.x + 0.48f));
        float large_y = 1.0f - smoothstep(0.42f - softness, 0.42f + softness, abs(direction.y - 0.02f));
        float large = large_x * large_y * smoothstep(0.0f, 0.12f, direction.z);
        float top_x = 1.0f - smoothstep(0.46f - softness, 0.46f + softness, abs(direction.x - 0.18f));
        float top_y = 1.0f - smoothstep(0.16f - softness, 0.16f + softness, abs(direction.y - 0.68f));
        float top = top_x * top_y * smoothstep(0.0f, 0.12f, direction.z);
        pattern_amount = min(1.0f, large + top * 0.55f + key_amount * 0.08f);
    } else if (p.panel_meta.w == 2) {
        float u = atan2(direction.x, direction.z) / (2.0f * PI) + 0.5f;
        float v = asin(direction.y) / PI + 0.5f;
        float longitude = abs(fract(u * 24.0f) - 0.5f);
        float latitude = abs(fract(v * 12.0f) - 0.5f);
        float lines = longitude > 0.46f || latitude > 0.43f ? 1.0f : 0.0f;
        float stop_band = clamp(floor(u * 8.0f), 0.0f, 7.0f);
        float calibrated = pow(2.0f, stop_band - 7.0f);
        pattern_amount = max(lines, calibrated);
    }
    float redistribution = clamp(p.cover_absorption_roughness.w * 0.75f + p.cover_haze.x * 0.25f, 0.0f, 1.0f);
    pattern_amount = mix(pattern_amount, 0.5f, redistribution);
    return (p.environment_ambient_strength.xyz + p.environment_key_radius.xyz * pattern_amount)
        * p.environment_ambient_strength.w;
}

inline float reflected_channel(RayHit hit, uint channel, float weight,
                               constant SpatialParams& p) {
    float cosine_t;
    float reflection = cover_interface(hit.cosine, p, cosine_t);
    return environment_radiance(hit.reflection_direction, p)[channel] * reflection * weight;
}

inline float3 procedural_signal(float2 uv, constant SpatialParams& p) {
    uint pattern = p.signal_meta.w;
    if (pattern == 2) {
        uint patch = min(uint(floor(clamp(uv.x, 0.0f, 1.0f - FLT_EPSILON) * 9.0f)), 8u);
        return PHOTOMETRIC_CODES[patch];
    }
    if (pattern == 0) {
        float pulse = sin(p.procedural_time.x * 0.8f) * 0.5f + 0.5f;
        int grid_x = int(floor(uv.x * 12.0f));
        int grid_y = int(floor(uv.y * 8.0f));
        float checker = ((grid_x + grid_y) % 2) == 0 ? 0.18f : 0.06f;
        float glow = max(0.0f, 1.0f - length(uv - 0.5f) * 1.8f);
        return float3(checker + glow * (0.45f + pulse * 0.25f),
                      checker + glow * (0.18f + (1.0f - pulse) * 0.18f),
                      checker + glow * 0.75f);
    }
    constexpr float centers[7] = {0.14f, 0.31f, 0.45f, 0.57f, 0.67f, 0.76f, 0.84f};
    constexpr float sizes[7] = {0.18f, 0.13f, 0.095f, 0.072f, 0.055f, 0.043f, 0.034f};
    for (uint row = 0; row < 7; ++row) {
        uint count = row + 1;
        float spacing = sizes[row] * 1.45f;
        float first_x = 0.5f - spacing * (float(count) - 1.0f) * 0.5f;
        for (uint column = 0; column < count; ++column) {
            float2 local = (uv - float2(first_x + spacing * float(column), centers[row])) / sizes[row];
            switch ((row + column) % 4) {
                case 1: local = float2(-local.y, local.x); break;
                case 2: local = -local; break;
                case 3: local = float2(local.y, -local.x); break;
                default: break;
            }
            bool vertical = local.x >= -0.5f && local.x <= -0.28f && abs(local.y) <= 0.5f;
            bool horizontal = abs(local.x) <= 0.5f
                && ((local.y >= -0.5f && local.y <= -0.30f) || abs(local.y) <= 0.10f
                    || (local.y >= 0.30f && local.y <= 0.5f));
            if (vertical || horizontal) return 0.0f;
        }
    }
    return 1.0f;
}

inline bool source_uv(float2 device_uv, constant SpatialParams& p, thread float2& result) {
    float source_aspect = float(p.signal_meta.x) / float(p.signal_meta.y);
    float device_aspect = float(p.panel_meta.x) / float(p.panel_meta.y);
    float2 scale = 1.0f;
    switch (p.signal_meta.z) {
        case 0: scale = source_aspect > device_aspect ? float2(1.0f, source_aspect / device_aspect)
                                                      : float2(device_aspect / source_aspect, 1.0f); break;
        case 1: scale = source_aspect > device_aspect ? float2(device_aspect / source_aspect, 1.0f)
                                                      : float2(1.0f, source_aspect / device_aspect); break;
        case 2: scale = 1.0f; break;
        default: scale = float2(float(p.panel_meta.x) / float(p.signal_meta.x),
                                float(p.panel_meta.y) / float(p.signal_meta.y)); break;
    }
    result = (device_uv - 0.5f) * scale + 0.5f;
    return all(result >= 0.0f) && all(result <= 1.0f);
}

inline float3 point_signal(float2 uv, device const float4* signal, constant SpatialParams& p) {
    if (p.window.w == 0) return procedural_signal(uv, p);
    float2 source;
    if (!source_uv(uv, p, source)) return 0.0f;
    uint x = min(uint(floor(source.x * float(p.signal_meta.x))), p.signal_meta.x - 1);
    uint y = min(uint(floor(source.y * float(p.signal_meta.y))), p.signal_meta.y - 1);
    return signal[y * p.signal_meta.x + x].xyz;
}

inline float4 row_prefix_at(device const float4* prefix, float x, uint row,
                            constant SpatialParams& p) {
    x = clamp(x, 0.0f, float(p.signal_meta.x));
    uint x0 = uint(floor(x));
    uint x1 = min(x0 + 1, p.signal_meta.x);
    float fx = x - float(x0);
    uint stride = p.signal_meta.x + 1;
    return mix(prefix[row * stride + x0], prefix[row * stride + x1], fx);
}

inline float3 raster_area(float2 minimum, float2 maximum, device const float4* prefix,
                          constant SpatialParams& p) {
    float2 first, second;
    source_uv(minimum, p, first); source_uv(maximum, p, second);
    float x0 = min(first.x, second.x) * float(p.signal_meta.x);
    float x1 = max(first.x, second.x) * float(p.signal_meta.x);
    float y0 = min(first.y, second.y) * float(p.signal_meta.y);
    float y1 = max(first.y, second.y) * float(p.signal_meta.y);
    float area = max(1.0e-8f, x1 - x0) * max(1.0e-8f, y1 - y0);
    float clipped_y0 = clamp(y0, 0.0f, float(p.signal_meta.y));
    float clipped_y1 = clamp(y1, 0.0f, float(p.signal_meta.y));
    uint first_row = min(uint(floor(clipped_y0)), p.signal_meta.y);
    uint final_row = min(uint(ceil(clipped_y1)), p.signal_meta.y);
    float4 sum = 0.0f;
    for (uint row = first_row; row < final_row; ++row) {
        float overlap = max(0.0f, min(clipped_y1, float(row + 1))
            - max(clipped_y0, float(row)));
        sum += (row_prefix_at(prefix, x1, row, p) - row_prefix_at(prefix, x0, row, p))
            * overlap;
    }
    return sum.xyz / area;
}

inline float3 area_signal(float2 minimum, float2 maximum, device const float4* integral,
                          constant SpatialParams& p, bool linear) {
    if (p.window.w != 0) return raster_area(minimum, maximum, integral, p);
    float3 sum = 0.0f;
    constexpr float offsets[4] = {0.125f, 0.375f, 0.625f, 0.875f};
    for (uint y = 0; y < 4; ++y) for (uint x = 0; x < 4; ++x) {
        float2 uv = mix(minimum, maximum, float2(offsets[x], offsets[y]));
        float3 code = procedural_signal(uv, p);
        if (linear) {
            float span = p.panel_levels_angular_r.y - p.panel_levels_angular_r.x;
            sum += p.panel_levels_angular_r.x + span * sign(code) * pow(abs(code), p.panel_geometry.w);
        } else sum += code;
    }
    return sum / 16.0f;
}

inline float periodic_integral(float position, float start, float end) {
    float cell = floor(position); float phase = position - cell;
    return cell * (end - start) + clamp(phase - start, 0.0f, end - start);
}

inline float linear_channel_over_rect(float value, float2 minimum, float2 maximum, uint channel,
                                      constant SpatialParams& p) {
    float width = maximum.x - minimum.x; float height = maximum.y - minimum.y;
    float margin = p.panel_geometry.z * 0.5f;
    float active = 1.0f - 2.0f * margin;
    uint emitter = p.panel_meta.z == 0 ? channel : 2 - channel;
    if (width <= FLT_EPSILON || height <= FLT_EPSILON) {
        float2 phase = fract(minimum);
        if (phase.x < margin || phase.x > 1.0f - margin || phase.y < margin || phase.y > 1.0f - margin) return 0.0f;
        uint stripe = uint(clamp(floor((phase.x - margin) / active * 3.0f), 0.0f, 2.0f));
        return stripe == emitter ? value * 3.0f / (active * active) : 0.0f;
    }
    float start = margin + float(emitter) * active / 3.0f;
    float end = margin + float(emitter + 1) * active / 3.0f;
    float covered_x = periodic_integral(maximum.x, start, end) - periodic_integral(minimum.x, start, end);
    float covered_y = periodic_integral(maximum.y, margin, 1.0f - margin)
        - periodic_integral(minimum.y, margin, 1.0f - margin);
    return value * (covered_x * covered_y / (width * height)) * 3.0f / (active * active);
}

inline float resolved_native_channel(float3 code, float2 uv, uint channel, constant SpatialParams& p) {
    float2 phase = fract(uv * float2(p.panel_meta.xy));
    float margin = p.panel_geometry.z * 0.5f; float active = 1.0f - 2.0f * margin;
    if (phase.x < margin || phase.x > 1.0f - margin || phase.y < margin || phase.y > 1.0f - margin) return 0.0f;
    uint stripe = uint(clamp(floor((phase.x - margin) / active * 3.0f), 0.0f, 2.0f));
    uint emitter = p.panel_meta.z == 0 ? stripe : 2 - stripe;
    if (emitter != channel) return 0.0f;
    float span = p.panel_levels_angular_r.y - p.panel_levels_angular_r.x;
    float linear = p.panel_levels_angular_r.x + span * sign(code[channel]) * pow(abs(code[channel]), p.panel_geometry.w);
    return linear * 3.0f / (active * active);
}

inline float channel_weight(float3 irradiance, RayHit hit, uint channel, constant SpatialParams& p) {
    float angular = hit.cosine == 0.0f ? 0.0f : pow(clamp(hit.cosine, 0.0f, 1.0f),
        channel == 0 ? p.panel_levels_angular_r.z : (channel == 1 ? p.panel_levels_angular_r.w : p.panel_angular_b.x));
    return irradiance[channel] * angular;
}

inline float2 footprint_offset(uint index, float psf) {
    constexpr float points[4] = {0.125f, 0.375f, 0.625f, 0.875f};
    float2 sample = float2(points[index % 4], points[index / 4]);
    float2 centered = 2.0f * sample - 1.0f;
    float2 disk = 0.0f;
    if (centered.x != 0.0f || centered.y != 0.0f) {
        float radius; float angle;
        if (abs(centered.x) > abs(centered.y)) {
            radius = centered.x; angle = (PI * 0.25f) * centered.y / centered.x;
        } else {
            radius = centered.y; angle = PI * 0.5f - (PI * 0.25f) * centered.x / centered.y;
        }
        disk = radius * float2(cos(angle), sin(angle));
    }
    return sample + disk * psf;
}

inline void evaluate_spatial_optics_pixel(device const float4* signal,
                                          device const float4* code_integral,
                                          device const float4* emission_integral,
                                          device float4* output,
                                          constant SpatialParams& p,
                                          uint index) {
    uint pixel_count = p.window.x * p.window.y;
    if (index >= pixel_count) return;
    uint local_x = index % p.window.x; uint local_y = index / p.window.x;
    uint column = p.raster.z + local_x; uint row = p.raster.w + local_y;
    float2 center_ndc = float2((float(column) + 0.5f) / float(p.raster.x) * 2.0f - 1.0f,
                               (float(row) + 0.5f) / float(p.raster.y) * 2.0f - 1.0f);
    float pitch_mm = p.camera_right_sensor_width.w / float(p.raster.x);
    float field = clamp(dot(center_ndc, center_ndc) * 0.5f, 0.0f, 1.0f);
    float softness_mm = mix(p.lens_softness.x, p.lens_softness.y, field) * 0.001f;
    float psf = ((softness_mm + 1.22f * 0.000550f * p.camera_limits.x) / pitch_mm)
        * p.pipeline_strengths.y;
    float minimum_offset = 0.001f - psf; float maximum_offset = 0.999f + psf;
    float2 corners[4] = {float2(minimum_offset, minimum_offset), float2(maximum_offset, minimum_offset),
                         float2(minimum_offset, maximum_offset), float2(maximum_offset, maximum_offset)};
    float2 ideal_corners[4]; bool ideal_valid[4];
    for (uint spatial = 0; spatial < 4; ++spatial) {
        float2 ndc = float2((float(column) + corners[spatial].x) / float(p.raster.x) * 2.0f - 1.0f,
                            (float(row) + corners[spatial].y) / float(p.raster.y) * 2.0f - 1.0f);
        ideal_valid[spatial] = inverse_distortion(float2(ndc.x + 2.0f * p.lens_shift_radial01.x,
                                                        -ndc.y - 2.0f * p.lens_shift_radial01.y), p,
                                                  ideal_corners[spatial]);
    }
    bool resolved = true; float3 reflected = 0.0f;
    for (uint channel = 0; channel < 3; ++channel) {
        float2 uv_min = INFINITY; float2 uv_max = -INFINITY; uint count = 0;
        for (uint spatial = 0; spatial < 4; ++spatial) if (ideal_valid[spatial]) {
            float3 weights = irradiance_weight(ideal_corners[spatial], p);
            for (uint aperture = 0; aperture < p.window.z; ++aperture) {
                RayHit hit = trace_ray(ideal_corners[spatial], aperture_sample(aperture), channel, p);
                if (!hit.valid) continue;
                float2 uv = transmitted_uv(hit, p);
                uv_min = min(uv_min, uv); uv_max = max(uv_max, uv); count++;
                if (all(hit.uv >= 0.0f) && all(hit.uv <= 1.0f))
                    reflected[channel] += reflected_channel(hit, channel, weights[channel], p);
            }
        }
        resolved = resolved && count > 0
            && (uv_max.x - uv_min.x) * float(p.panel_meta.x) <= (1.0f / 3.0f)
            && (uv_max.y - uv_min.y) * float(p.panel_meta.y) <= 1.0f;
    }
    reflected /= float(p.window.z * 4);
    float3 native = 0.0f; bool on_panel = false;
    if (!resolved) {
        for (uint aperture = 0; aperture < p.window.z; ++aperture) for (uint channel = 0; channel < 3; ++channel) {
            float2 uv_min = INFINITY; float2 uv_max = -INFINITY; float weight_sum = 0.0f; uint count = 0;
            for (uint spatial = 0; spatial < 4; ++spatial) if (ideal_valid[spatial]) {
                RayHit hit = trace_ray(ideal_corners[spatial], aperture_sample(aperture), channel, p);
                if (!hit.valid) continue;
                float2 uv = transmitted_uv(hit, p);
                if (!all(uv >= 0.0f) || !all(uv <= 1.0f)) continue;
                uv_min = min(uv_min, uv); uv_max = max(uv_max, uv);
                float3 weights = irradiance_weight(ideal_corners[spatial], p);
                weight_sum += channel_weight(weights, hit, channel, p) * cover_transmission(hit.cosine, p)[channel];
                count++;
            }
            if (count == 0) continue;
            on_panel = true;
            float ideal = area_signal(uv_min, uv_max, emission_integral, p, true)[channel];
            float physical = linear_channel_over_rect(ideal, uv_min * float2(p.panel_meta.xy),
                                                      uv_max * float2(p.panel_meta.xy), channel, p);
            float value = max(ideal + p.pipeline_strengths.x * (physical - ideal), 0.0f);
            native[channel] += value * weight_sum / 4.0f;
        }
        native /= float(p.window.z);
    } else {
        for (uint spatial = 0; spatial < 16; ++spatial) {
            float2 offset = footprint_offset(spatial, psf);
            float2 ndc = float2((float(column) + offset.x) / float(p.raster.x) * 2.0f - 1.0f,
                                (float(row) + offset.y) / float(p.raster.y) * 2.0f - 1.0f);
            float2 ideal;
            if (!inverse_distortion(float2(ndc.x + 2.0f * p.lens_shift_radial01.x,
                                           -ndc.y - 2.0f * p.lens_shift_radial01.y), p, ideal)) continue;
            float3 weights = irradiance_weight(ideal, p);
            for (uint aperture = 0; aperture < p.window.z; ++aperture) for (uint channel = 0; channel < 3; ++channel) {
                RayHit hit = trace_ray(ideal, aperture_sample(aperture), channel, p);
                if (!hit.valid) continue;
                float2 uv = transmitted_uv(hit, p);
                if (!all(uv >= 0.0f) || !all(uv <= 1.0f)) continue;
                on_panel = true;
                float3 code = point_signal(uv, signal, p);
                float span = p.panel_levels_angular_r.y - p.panel_levels_angular_r.x;
                float ideal = p.panel_levels_angular_r.x
                    + span * sign(code[channel]) * pow(abs(code[channel]), p.panel_geometry.w);
                float physical = resolved_native_channel(code, uv, channel, p);
                float value = max(ideal + p.pipeline_strengths.x * (physical - ideal), 0.0f);
                native[channel] += value * channel_weight(weights, hit, channel, p)
                    * cover_transmission(hit.cosine, p)[channel];
            }
        }
        native /= float(p.window.z * 16);
    }
    float3 acescg = float3(dot(p.panel_matrix_0.xyz, native), dot(p.panel_matrix_1.xyz, native),
                           dot(p.panel_matrix_2.xyz, native)) + reflected;
    output[index] = float4(acescg, on_panel ? 1.0f : 0.0f);
}

kernel void evaluate_spatial_optics(device const float4* signal [[buffer(0)]],
                                    device const float4* code_integral [[buffer(1)]],
                                    device const float4* emission_integral [[buffer(2)]],
                                    device float4* output [[buffer(3)]],
                                    constant SpatialParams& p [[buffer(4)]],
                                    uint index [[thread_position_in_grid]]) {
    evaluate_spatial_optics_pixel(signal, code_integral, emission_integral, output, p, index);
}

kernel void evaluate_spatial_optics_batch(device const float4* signal [[buffer(0)]],
                                          device const float4* code_integral [[buffer(1)]],
                                          device const float4* emission_integral [[buffer(2)]],
                                          device float4* output [[buffer(3)]],
                                          constant SpatialParams* params [[buffer(4)]],
                                          constant uint2& batch [[buffer(5)]],
                                          uint index [[thread_position_in_grid]]) {
    uint pixel_count = batch.x;
    uint job = index / pixel_count;
    if (job >= batch.y) return;
    evaluate_spatial_optics_pixel(signal, code_integral, emission_integral,
                                  output + job * pixel_count, params[job], index % pixel_count);
}
