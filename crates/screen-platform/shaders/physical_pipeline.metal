#include <metal_stdlib>
using namespace metal;

struct PhysicalPipelineParams {
    uint4 source_panel; // source width, source height, panel width, panel height
    uint4 output_tile;  // output width, output height, tile origin y, sample side
    uint4 semantics;    // placement, stripe layout, reserved, reserved
    float4 levels;      // gamma, black nits, white nits, amount
    float4 geometry;    // black matrix fraction, reserved...
    float4 strengths;   // screen, emission, subpixel geometry, reserved
    float4 matrix0;
    float4 matrix1;
    float4 matrix2;
    float4 panel_size_meters;
    float4 spread_core_radius;
    float4 spread_core_weight;
    float4 spread_tail_radius;
    float4 spread_tail_weight;
};

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
            ideal += area_sample(source_acescg, minimum_uv, maximum_uv, p);
            const float4 code = area_sample(device_signal, minimum_uv, maximum_uv, p);
            average_device_code += code.rgb;
            const float2 device_minimum = minimum_uv * float2(p.source_panel.zw);
            const float2 device_maximum = maximum_uv * float2(p.source_panel.zw);
            native.x += native_channel(code.x, 0, device_minimum, device_maximum, p);
            native.y += native_channel(code.y, 1, device_minimum, device_maximum, p);
            native.z += native_channel(code.z, 2, device_minimum, device_maximum, p);
            spread_native.x += spread_native_channel(device_signal, 0, minimum_uv, maximum_uv, p);
            spread_native.y += spread_native_channel(device_signal, 1, minimum_uv, maximum_uv, p);
            spread_native.z += spread_native_channel(device_signal, 2, minimum_uv, maximum_uv, p);
            continuous_native += float3(
                continuous_channel(code.x, p),
                continuous_channel(code.y, p),
                continuous_channel(code.z, p)
            );
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
    float3 selected;
    switch (p.semantics.z) {
        case 0: selected = ideal.rgb; break;
        case 1: selected = average_device_code; break;
        case 2: selected = continuous; break;
        case 3: selected = physical; break;
        case 4: selected = spread; break;
        default: selected = ideal.rgb + p.strengths.x * (staged - ideal.rgb); break;
    }
    output.write(float4(selected, ideal.a), position);
}
