#include <metal_stdlib>
using namespace metal;

struct PhysicalPipelineParams {
    uint4 source_panel; // source width, source height, panel width, panel height
    uint4 output_tile;  // output width, output height, tile origin y, sample side
    uint4 semantics;    // placement, stripe layout, reserved, reserved
    float4 levels;      // gamma, black nits, white nits, temporal calibrated gain
    float4 geometry;    // black matrix fraction, reserved...
    float4 strengths;   // screen, emission, subpixel geometry, temporal emission
    float4 matrix0;
    float4 matrix1;
    float4 matrix2;
    float4 panel_size_meters;
    float4 spread_core_radius;
    float4 spread_core_weight;
    float4 spread_tail_radius;
    float4 spread_tail_weight;
    float4 cover_geometry;
    float4 cover_absorption_roughness;
    float4 cover_haze;
    float4 environment_ambient_strength;
    float4 environment_key_radius;
    float4 environment_direction_rotation;
    float4 camera_position_focal;
    float4 camera_right_sensor_width;
    float4 camera_up_sensor_height;
    float4 camera_forward_focus;
    float4 camera_limits;
    float4 lens_shift_radial01;
    float4 lens_radial2_tangential;
    float4 lens_longitudinal;
    float4 lens_lateral;
    float4 lens_transmission_vignette;
    float4 lens_softness;
    float4 screen_translation;
    float4 screen_quaternion;
    float4 panel_angular_scene;
    float4 shutter;
};

constant float PI = 3.14159265358979323846f;
constant float GOLDEN_ANGLE = 2.3999631f;

struct PhysicalRayHit {
    float2 uv;
    float cosine;
    float3 reflection_direction;
    bool valid;
};

inline float3 physical_quaternion_rotate(float4 quaternion, float3 value) {
    const float3 t = 2.0f * cross(quaternion.xyz, value);
    return value + quaternion.w * t + cross(quaternion.xyz, t);
}

inline float2 physical_distort(float2 point, constant PhysicalPipelineParams& p) {
    const float radius2 = dot(point, point);
    const float radial = 1.0f + p.lens_shift_radial01.z * radius2
        + p.lens_shift_radial01.w * radius2 * radius2
        + p.lens_radial2_tangential.x * radius2 * radius2 * radius2;
    const float p1 = p.lens_radial2_tangential.y;
    const float p2 = p.lens_radial2_tangential.z;
    return float2(point.x * radial + 2.0f * p1 * point.x * point.y
            + p2 * (radius2 + 2.0f * point.x * point.x),
        point.y * radial + p1 * (radius2 + 2.0f * point.y * point.y)
            + 2.0f * p2 * point.x * point.y);
}

inline bool physical_inverse_distortion(float2 observed, constant PhysicalPipelineParams& p,
                                        thread float2& ideal) {
    ideal = observed;
    constexpr float epsilon = 1.0e-4f;
    for (uint iteration = 0; iteration < 12; ++iteration) {
        const float2 projected = physical_distort(ideal, p);
        const float2 residual = observed - projected;
        if (max(abs(residual.x), abs(residual.y)) < 1.0e-6f) return true;
        const float2 dx = physical_distort(ideal + float2(epsilon, 0.0f), p);
        const float2 dy = physical_distort(ideal + float2(0.0f, epsilon), p);
        const float j00 = (dx.x - projected.x) / epsilon;
        const float j10 = (dx.y - projected.y) / epsilon;
        const float j01 = (dy.x - projected.x) / epsilon;
        const float j11 = (dy.y - projected.y) / epsilon;
        const float determinant = j00 * j11 - j01 * j10;
        if (!isfinite(determinant) || determinant <= 1.0e-8f) return false;
        ideal += float2(j11 * residual.x - j01 * residual.y,
            -j10 * residual.x + j00 * residual.y) / determinant;
        if (!all(isfinite(ideal))) return false;
    }
    const float2 residual = physical_distort(ideal, p) - observed;
    return max(abs(residual.x), abs(residual.y)) < 1.0e-5f;
}

inline float physical_radical_inverse(uint value) {
    return float(reverse_bits(value)) * (1.0f / 4294967296.0f);
}

inline float2 physical_aperture_sample(uint index) {
    const float radius = sqrt(physical_radical_inverse(index + 1));
    const float angle = float(index) * GOLDEN_ANGLE;
    return radius * float2(cos(angle), sin(angle));
}

inline PhysicalRayHit physical_trace_ray(float2 observed, float2 lens_sample, uint channel,
                                         constant PhysicalPipelineParams& p) {
    PhysicalRayHit miss;
    miss.uv = 0.0f; miss.cosine = 0.0f; miss.reflection_direction = 0.0f; miss.valid = false;
    float2 ideal;
    if (!physical_inverse_distortion(float2(observed.x + 2.0f * p.lens_shift_radial01.x,
        -observed.y - 2.0f * p.lens_shift_radial01.y), p, ideal)) return miss;
    ideal *= p.lens_lateral[channel];
    const float3 pinhole = normalize(p.camera_forward_focus.xyz
        + p.camera_right_sensor_width.xyz * (ideal.x * p.camera_right_sensor_width.w
            / (2.0f * p.camera_position_focal.w))
        + p.camera_up_sensor_height.xyz * (ideal.y * p.camera_up_sensor_height.w
            / (2.0f * p.camera_position_focal.w)));
    const float channel_focus = p.camera_forward_focus.w + p.lens_longitudinal[channel];
    const float3 focus_point = p.camera_position_focal.xyz
        + pinhole * (channel_focus / dot(pinhole, p.camera_forward_focus.xyz));
    const float aperture_radius = p.camera_position_focal.w * 0.001f / (2.0f * p.camera_limits.x);
    const float3 lens_origin = p.camera_position_focal.xyz
        + p.camera_right_sensor_width.xyz * (lens_sample.x * aperture_radius)
        + p.camera_up_sensor_height.xyz * (lens_sample.y * aperture_radius);
    const float3 ray = normalize(focus_point - lens_origin);
    const float4 inverse = float4(-p.screen_quaternion.xyz, p.screen_quaternion.w);
    const float3 local_origin = physical_quaternion_rotate(inverse,
        lens_origin - p.screen_translation.xyz);
    const float3 local_ray = physical_quaternion_rotate(inverse, ray);
    if (abs(local_ray.z) < 1.0e-8f) return miss;
    const float distance = -local_origin.z / local_ray.z;
    if (distance <= 0.0f) return miss;
    const float3 local_point = local_origin + local_ray * distance;
    const float3 world_point = p.screen_translation.xyz
        + physical_quaternion_rotate(p.screen_quaternion, local_point);
    const float depth = dot(world_point - p.camera_position_focal.xyz, p.camera_forward_focus.xyz);
    if (depth < p.camera_limits.y || depth > p.camera_limits.z) return miss;
    PhysicalRayHit hit;
    hit.uv = float2(local_point.x / p.panel_size_meters.x + 0.5f,
        0.5f - local_point.y / p.panel_size_meters.y);
    hit.cosine = clamp(-local_ray.z, 0.0f, 1.0f);
    hit.reflection_direction = float3(local_ray.x, local_ray.y, -local_ray.z);
    hit.valid = true;
    return hit;
}

inline float physical_irradiance_weight(float2 observed, uint channel,
                                        constant PhysicalPipelineParams& p) {
    float2 ideal;
    if (!physical_inverse_distortion(float2(observed.x + 2.0f * p.lens_shift_radial01.x,
        -observed.y - 2.0f * p.lens_shift_radial01.y), p, ideal)) return 0.0f;
    const float scale = p.lens_lateral[channel];
    const float tangent_x = ideal.x * scale * p.camera_right_sensor_width.w
        / (2.0f * p.camera_position_focal.w);
    const float tangent_y = ideal.y * scale * p.camera_up_sensor_height.w
        / (2.0f * p.camera_position_focal.w);
    const float cosine = rsqrt(1.0f + tangent_x * tangent_x + tangent_y * tangent_y);
    const float natural = cosine * cosine * cosine * cosine;
    const float vignette = 1.0f + (natural - 1.0f) * p.lens_transmission_vignette.w;
    return (PI * 0.25f) / (p.camera_limits.x * p.camera_limits.x)
        * vignette * p.lens_transmission_vignette[channel];
}

inline float cover_interface(float cosine_i, constant PhysicalPipelineParams& p) {
    const float eta = p.cover_geometry.z;
    const float sine_t2 = (1.0f - cosine_i * cosine_i) / (eta * eta);
    const float cosine_t = sqrt(max(0.0f, 1.0f - sine_t2));
    if (eta == 1.0f || p.cover_geometry.w == 1.0f) return 0.0f;
    const float rs = (cosine_i - eta * cosine_t) / max(1.0e-8f, cosine_i + eta * cosine_t);
    const float rp = (eta * cosine_i - cosine_t) / max(1.0e-8f, eta * cosine_i + cosine_t);
    return clamp(0.5f * (rs * rs + rp * rp) * (1.0f - p.cover_geometry.w)
        * p.cover_geometry.x, 0.0f, 0.98f);
}

inline float3 flat_environment_radiance(constant PhysicalPipelineParams& p) {
    float3 direction = float3(0.0f, 0.0f, 1.0f);
    const float sine = sin(p.environment_direction_rotation.w);
    const float cosine = cos(p.environment_direction_rotation.w);
    direction = float3(direction.x * cosine + direction.z * sine, direction.y,
        -direction.x * sine + direction.z * cosine);
    const float alignment = clamp(dot(direction, p.environment_direction_rotation.xyz), -1.0f, 1.0f);
    const float edge = cos(p.environment_key_radius.w);
    const float softness = 0.005f + p.cover_absorption_roughness.w * 0.35f;
    const float key_amount = smoothstep(edge - softness, edge + softness, alignment);
    float pattern_amount = 0.0f;
    if (p.semantics.w == 1) {
        const float large = (1.0f - smoothstep(0.30f - softness, 0.30f + softness, abs(direction.x + 0.48f)))
            * (1.0f - smoothstep(0.42f - softness, 0.42f + softness, abs(direction.y - 0.02f)))
            * smoothstep(0.0f, 0.12f, direction.z);
        const float top = (1.0f - smoothstep(0.46f - softness, 0.46f + softness, abs(direction.x - 0.18f)))
            * (1.0f - smoothstep(0.16f - softness, 0.16f + softness, abs(direction.y - 0.68f)))
            * smoothstep(0.0f, 0.12f, direction.z);
        pattern_amount = min(1.0f, large + top * 0.55f + key_amount * 0.08f);
    } else if (p.semantics.w == 2) {
        const float u = atan2(direction.x, direction.z) / (2.0f * PI) + 0.5f;
        const float v = asin(direction.y) / PI + 0.5f;
        const float longitude = abs(fract(u * 24.0f) - 0.5f);
        const float latitude = abs(fract(v * 12.0f) - 0.5f);
        const float lines = longitude > 0.46f || latitude > 0.43f ? 1.0f : 0.0f;
        pattern_amount = max(lines, pow(2.0f, clamp(floor(u * 8.0f), 0.0f, 7.0f) - 7.0f));
    }
    const float redistribution = clamp(p.cover_absorption_roughness.w * 0.75f
        + p.cover_haze.x * 0.25f, 0.0f, 1.0f);
    pattern_amount = mix(pattern_amount, 0.5f, redistribution);
    return (p.environment_ambient_strength.xyz + p.environment_key_radius.xyz * pattern_amount)
        * p.environment_ambient_strength.w;
}

inline float3 apply_flat_cover(float3 emitted, constant PhysicalPipelineParams& p) {
    const float reflection = cover_interface(1.0f, p);
    const float absorption_scale = p.cover_geometry.y * p.cover_geometry.x;
    const float haze_loss = clamp(p.cover_haze.x * p.cover_geometry.x, 0.0f, 0.95f);
    const float3 transmission = (1.0f - reflection)
        * exp(-p.cover_absorption_roughness.xyz * absorption_scale) * (1.0f - haze_loss);
    return emitted * transmission + flat_environment_radiance(p) * reflection / p.levels.z;
}

inline float2 placement_scale(constant PhysicalPipelineParams& p) {
    const float source_aspect = float(p.source_panel.x) / float(p.source_panel.y);
    const float panel_aspect = float(p.source_panel.z) / float(p.source_panel.w);
    const uint placement = p.semantics.x;
    if (placement == 0) {
        return source_aspect > panel_aspect
            ? float2(1.0f, source_aspect / panel_aspect)
            : float2(panel_aspect / source_aspect, 1.0f);
    }
    if (placement == 1) {
        return source_aspect > panel_aspect
            ? float2(panel_aspect / source_aspect, 1.0f)
            : float2(1.0f, source_aspect / panel_aspect);
    }
    if (placement == 3) {
        return float2(
            float(p.source_panel.z) / float(p.source_panel.x),
            float(p.source_panel.w) / float(p.source_panel.y)
        );
    }
    return float2(1.0f);
}

inline float4 area_sample(
    texture2d<float, access::read> texture,
    float2 device_minimum,
    float2 device_maximum,
    constant PhysicalPipelineParams& p
) {
    const float2 scale = placement_scale(p);
    const float2 source_size = float2(p.source_panel.xy);
    float2 minimum = ((device_minimum - 0.5f) * scale + 0.5f) * source_size;
    float2 maximum = ((device_maximum - 0.5f) * scale + 0.5f) * source_size;
    minimum = min(minimum, maximum);
    maximum = max(minimum, maximum);
    const float area = max((maximum.x - minimum.x) * (maximum.y - minimum.y), 1.0e-12f);
    const int2 first = int2(floor(minimum));
    const int2 last = int2(ceil(maximum));
    float4 sum = 0.0f;
    for (int y = first.y; y < last.y; ++y) {
        if (y < 0 || y >= int(p.source_panel.y)) continue;
        const float wy = max(0.0f, min(maximum.y, float(y + 1)) - max(minimum.y, float(y)));
        for (int x = first.x; x < last.x; ++x) {
            if (x < 0 || x >= int(p.source_panel.x)) continue;
            const float wx = max(0.0f, min(maximum.x, float(x + 1)) - max(minimum.x, float(x)));
            sum += texture.read(uint2(x, y)) * (wx * wy);
        }
    }
    return sum / area;
}

inline float periodic_integral(float position, float start, float end) {
    const float cell = floor(position);
    const float phase = position - cell;
    return cell * (end - start) + clamp(phase - start, 0.0f, end - start);
}

inline float periodic_coverage(float minimum, float maximum, float start, float end) {
    return periodic_integral(maximum, start, end)
        - periodic_integral(minimum, start, end);
}

inline float native_channel(
    float code,
    uint channel,
    float2 device_minimum,
    float2 device_maximum,
    constant PhysicalPipelineParams& p
) {
    const float span = p.levels.z - p.levels.y;
    const float linear = p.levels.y + span * sign(code) * pow(abs(code), p.levels.x);
    const float margin = p.geometry.x * 0.5f;
    const float active = 1.0f - 2.0f * margin;
    const uint emitter = p.semantics.y == 0 ? channel : 2 - channel;
    const float stripe_start = margin + float(emitter) * active / 3.0f;
    const float stripe_end = margin + float(emitter + 1) * active / 3.0f;
    const float covered_x = periodic_coverage(
        device_minimum.x, device_maximum.x, stripe_start, stripe_end
    );
    const float covered_y = periodic_coverage(
        device_minimum.y, device_maximum.y, margin, 1.0f - margin
    );
    const float area = max(
        (device_maximum.x - device_minimum.x)
            * (device_maximum.y - device_minimum.y),
        1.0e-12f
    );
    return linear * (covered_x * covered_y / area) * 3.0f / (active * active);
}

inline float continuous_channel(float code, constant PhysicalPipelineParams& p) {
    const float span = p.levels.z - p.levels.y;
    return p.levels.y + span * sign(code) * pow(abs(code), p.levels.x);
}

inline float native_channel_at_offset(
    texture2d<float, access::read> device_signal,
    uint channel,
    float2 device_minimum,
    float2 device_maximum,
    float2 offset_uv,
    constant PhysicalPipelineParams& p
) {
    const float2 shifted_minimum = device_minimum + offset_uv;
    const float2 shifted_maximum = device_maximum + offset_uv;
    const float4 code = area_sample(device_signal, shifted_minimum, shifted_maximum, p);
    return native_channel(
        code[channel],
        channel,
        shifted_minimum * float2(p.source_panel.zw),
        shifted_maximum * float2(p.source_panel.zw),
        p
    );
}

inline float spread_native_channel(
    texture2d<float, access::read> device_signal,
    uint channel,
    float2 device_minimum,
    float2 device_maximum,
    constant PhysicalPipelineParams& p
) {
    const float strength = p.spread_core_radius.w;
    if (strength == 0.0f) {
        return native_channel_at_offset(
            device_signal, channel, device_minimum, device_maximum, float2(0.0f), p
        );
    }
    const float core_weight = p.spread_core_weight[channel];
    const float tail_weight = p.spread_tail_weight[channel];
    const float2 inverse_panel = 1.0f / p.panel_size_meters.xy;
    const float core = p.spread_core_radius[channel] * strength * 1.0e-6f;
    const float tail = p.spread_tail_radius[channel] * strength * 0.7071067811865475f * 1.0e-6f;
    float value = native_channel_at_offset(
        device_signal, channel, device_minimum, device_maximum, float2(0.0f), p
    ) * (1.0f - core_weight - tail_weight);
    const float core_sample = core_weight * 0.25f;
    const float tail_sample = tail_weight * 0.25f;
    value += native_channel_at_offset(device_signal, channel, device_minimum, device_maximum, float2(core, 0.0f) * inverse_panel, p) * core_sample;
    value += native_channel_at_offset(device_signal, channel, device_minimum, device_maximum, float2(-core, 0.0f) * inverse_panel, p) * core_sample;
    value += native_channel_at_offset(device_signal, channel, device_minimum, device_maximum, float2(0.0f, core) * inverse_panel, p) * core_sample;
    value += native_channel_at_offset(device_signal, channel, device_minimum, device_maximum, float2(0.0f, -core) * inverse_panel, p) * core_sample;
    value += native_channel_at_offset(device_signal, channel, device_minimum, device_maximum, float2(tail, tail) * inverse_panel, p) * tail_sample;
    value += native_channel_at_offset(device_signal, channel, device_minimum, device_maximum, float2(-tail, tail) * inverse_panel, p) * tail_sample;
    value += native_channel_at_offset(device_signal, channel, device_minimum, device_maximum, float2(tail, -tail) * inverse_panel, p) * tail_sample;
    value += native_channel_at_offset(device_signal, channel, device_minimum, device_maximum, float2(-tail, -tail) * inverse_panel, p) * tail_sample;
    return value;
}

kernel void evaluate_physical_pipeline(
    texture2d<float, access::read> source_acescg [[texture(0)]],
    texture2d<float, access::read> device_signal [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    constant PhysicalPipelineParams& p [[buffer(0)]],
    device const float* row_temporal_gains [[buffer(1)]],
    uint2 local_position [[thread_position_in_grid]]
) {
    const uint2 position = uint2(local_position.x, local_position.y + p.output_tile.z);
    if (position.x >= p.output_tile.x || position.y >= p.output_tile.y) return;
    const uint side = p.output_tile.w;
    float4 ideal = 0.0f;
    float3 native = 0.0f;
    float3 spread_native = 0.0f;
    float3 continuous_native = 0.0f;
    float3 average_device_code = 0.0f;
    for (uint sy = 0; sy < side; ++sy) {
        for (uint sx = 0; sx < side; ++sx) {
            const float2 minimum_uv = (
                float2(position) + float2(sx, sy) / float(side)
            ) / float2(p.output_tile.xy);
            const float2 maximum_uv = (
                float2(position) + float2(sx + 1, sy + 1) / float(side)
            ) / float2(p.output_tile.xy);
            const float2 flat_center = (minimum_uv + maximum_uv) * 0.5f;
            const float2 observed = flat_center * 2.0f - 1.0f;
            const float field = clamp(dot(observed, observed) * 0.5f, 0.0f, 1.0f);
            const float softness_mm = mix(p.lens_softness.x, p.lens_softness.y, field) * 0.001f;
            const float sensor_pitch_mm = p.camera_right_sensor_width.w / float(p.output_tile.x);
            const float psf_pixels = ((softness_mm + 1.22f * 0.000550f * p.camera_limits.x)
                / sensor_pitch_mm) * p.lens_softness.z;
            const float2 half_extent = (maximum_uv - minimum_uv) * 0.5f * (1.0f + psf_pixels);
            const float2 lens_sample = physical_aperture_sample((sy * side + sx) % 16);
            for (uint channel = 0; channel < 3; ++channel) {
                const PhysicalRayHit hit = physical_trace_ray(observed, lens_sample, channel, p);
                const float2 target = hit.valid ? hit.uv : float2(-2.0f);
                const float2 center = mix(flat_center, target, p.panel_angular_scene.w);
                const bool exact_flat = p.panel_angular_scene.w == 0.0f && p.lens_softness.z == 0.0f;
                const float2 channel_minimum = exact_flat ? minimum_uv : center - half_extent;
                const float2 channel_maximum = exact_flat ? maximum_uv : center + half_extent;
                const float angular = hit.valid && hit.cosine != 0.0f
                    ? pow(clamp(hit.cosine, 0.0f, 1.0f), p.panel_angular_scene[channel])
                        * physical_irradiance_weight(observed, channel, p)
                    : 0.0f;
                const float optical_weight = mix(1.0f, angular, p.panel_angular_scene.w);
                const float4 code = area_sample(device_signal, channel_minimum, channel_maximum, p);
                average_device_code[channel] += code[channel];
                const float2 device_minimum = channel_minimum * float2(p.source_panel.zw);
                const float2 device_maximum = channel_maximum * float2(p.source_panel.zw);
                native[channel] += native_channel(code[channel], channel, device_minimum,
                    device_maximum, p) * optical_weight;
                spread_native[channel] += spread_native_channel(device_signal, channel,
                    channel_minimum, channel_maximum, p) * optical_weight;
                continuous_native[channel] += continuous_channel(code[channel], p) * optical_weight;
            }
            const PhysicalRayHit green_hit = physical_trace_ray(observed, lens_sample, 1, p);
            const float2 green_target = green_hit.valid ? green_hit.uv : float2(-2.0f);
            const float2 green_center = mix(flat_center, green_target, p.panel_angular_scene.w);
            const bool exact_flat = p.panel_angular_scene.w == 0.0f && p.lens_softness.z == 0.0f;
            ideal += area_sample(source_acescg,
                exact_flat ? minimum_uv : green_center - half_extent,
                exact_flat ? maximum_uv : green_center + half_extent, p);
        }
    }
    const float reciprocal = 1.0f / float(side * side);
    ideal *= reciprocal;
    native *= reciprocal;
    spread_native *= reciprocal;
    continuous_native *= reciprocal;
    average_device_code *= reciprocal;
    const float3 physical = float3(
        dot(p.matrix0.xyz, native),
        dot(p.matrix1.xyz, native),
        dot(p.matrix2.xyz, native)
    ) / p.levels.z;
    const float3 continuous = float3(
        dot(p.matrix0.xyz, continuous_native),
        dot(p.matrix1.xyz, continuous_native),
        dot(p.matrix2.xyz, continuous_native)
    ) / p.levels.z;
    const float3 spread = float3(
        dot(p.matrix0.xyz, spread_native),
        dot(p.matrix1.xyz, spread_native),
        dot(p.matrix2.xyz, spread_native)
    ) / p.levels.z;
    const float3 staged = ideal.rgb
        + p.strengths.y * (continuous - ideal.rgb)
        + p.strengths.z * (physical - continuous)
        + (spread - physical);
    const float temporal_gain = 1.0f + p.strengths.w * (row_temporal_gains[position.y] - 1.0f);
    const float3 temporally_integrated = staged * temporal_gain;
    const float3 covered = apply_flat_cover(temporally_integrated, p);
    const float shutter_scale = pow(p.shutter.y * exp2(-p.shutter.z), p.shutter.x);
    const float3 shuttered = covered * shutter_scale;
    float3 selected;
    switch (p.semantics.z) {
        case 0: selected = ideal.rgb; break;
        case 1: selected = average_device_code; break;
        case 2: selected = continuous; break;
        case 3: selected = physical; break;
        case 4: selected = spread; break;
        case 5: selected = covered; break;
        case 6: selected = covered; break;
        case 7: selected = shuttered; break;
        default: selected = ideal.rgb + p.strengths.x * (shuttered - ideal.rgb); break;
    }
    output.write(float4(selected, ideal.a), position);
}

kernel void accumulate_physical_pipeline(
    texture2d<float, access::read> sample [[texture(0)]],
    texture2d<float, access::read_write> accumulated [[texture(1)]],
    constant float2 &weight_reset [[buffer(0)]],
    uint2 position [[thread_position_in_grid]])
{
    if (position.x >= sample.get_width() || position.y >= sample.get_height()) {
        return;
    }
    const float4 weighted = sample.read(position) * weight_reset.x;
    accumulated.write(weight_reset.y != 0.0f ? weighted : accumulated.read(position) + weighted,
        position);
}
