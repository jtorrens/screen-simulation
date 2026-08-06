#include <metal_stdlib>
using namespace metal;

struct FlatPanelParams {
    uint4 source_panel; // source width, source height, panel width, panel height
    uint4 output_tile;  // output width, output height, tile origin y, sample side
    uint4 semantics;    // placement, stripe layout, reserved, reserved
    float4 levels;      // gamma, black nits, white nits, amount
    float4 geometry;    // black matrix fraction, reserved...
    float4 matrix0;
    float4 matrix1;
    float4 matrix2;
};

inline float2 placement_scale(constant FlatPanelParams& p) {
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
    constant FlatPanelParams& p
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
    constant FlatPanelParams& p
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

kernel void evaluate_flat_panel(
    texture2d<float, access::read> source_acescg [[texture(0)]],
    texture2d<float, access::read> device_signal [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    constant FlatPanelParams& p [[buffer(0)]],
    uint2 local_position [[thread_position_in_grid]]
) {
    const uint2 position = uint2(local_position.x, local_position.y + p.output_tile.z);
    if (position.x >= p.output_tile.x || position.y >= p.output_tile.y) return;
    const uint side = p.output_tile.w;
    float4 ideal = 0.0f;
    float3 native = 0.0f;
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
            const float2 device_minimum = minimum_uv * float2(p.source_panel.zw);
            const float2 device_maximum = maximum_uv * float2(p.source_panel.zw);
            native.x += native_channel(code.x, 0, device_minimum, device_maximum, p);
            native.y += native_channel(code.y, 1, device_minimum, device_maximum, p);
            native.z += native_channel(code.z, 2, device_minimum, device_maximum, p);
        }
    }
    const float reciprocal = 1.0f / float(side * side);
    ideal *= reciprocal;
    native *= reciprocal;
    const float3 physical = float3(
        dot(p.matrix0.xyz, native),
        dot(p.matrix1.xyz, native),
        dot(p.matrix2.xyz, native)
    ) / p.levels.z;
    output.write(float4(ideal.rgb + p.levels.w * (physical - ideal.rgb), ideal.a), position);
}
