#include <metal_stdlib>
using namespace metal;

struct CameraParams {
    uint width;
    uint height;
    uint origin_x;
    uint origin_y;
    uint pattern;
    uint maximum_code;
    float analog_gain;
    float linear_scale;
    float4 saturation;
    float4 white_balance;
    float4 sensor_to_acescg_0;
    float4 sensor_to_acescg_1;
    float4 sensor_to_acescg_2;
    float4 rendering_intent;
    float4 rendering_white_gains;
};

inline float signed_contrast(float value, float contrast) {
    return sign(value) * 0.18f * pow(abs(value) / 0.18f, contrast);
}

struct RawPublicationParams {
    uint width;
    uint height;
    uint maximum_code;
    uint padding;
};

inline uint cfa_channel(uint pattern, int x, int y) {
    uint parity = (uint(y & 1) << 1) | uint(x & 1);
    constexpr uint table[4][4] = {
        {0, 1, 1, 2}, {2, 1, 1, 0}, {1, 0, 2, 1}, {1, 2, 0, 1}
    };
    return table[pattern][parity];
}

kernel void publish_sensor_raw(device const ushort* codes [[buffer(0)]],
                               device const uchar2* clipping [[buffer(1)]],
                               texture2d<float, access::write> output [[texture(0)]],
                               constant RawPublicationParams& p [[buffer(2)]],
                               uint2 position [[thread_position_in_grid]]) {
    if (position.x >= p.width || position.y >= p.height) return;
    const uint index = position.y * p.width + position.x;
    output.write(float4(float(codes[index]) / float(p.maximum_code),
                        float(clipping[index].x), float(clipping[index].y), 1.0f), position);
}

inline bool local_index(constant CameraParams& p, int x, int y, thread uint& index) {
    int lx = x - int(p.origin_x);
    int ly = y - int(p.origin_y);
    if (lx < 0 || ly < 0 || lx >= int(p.width) || ly >= int(p.height)) return false;
    index = uint(ly) * p.width + uint(lx);
    return true;
}

inline bool mosaic_at(device const ushort* codes, constant CameraParams& p,
                      int x, int y, thread float& value) {
    uint index;
    if (!local_index(p, x, y, index)) return false;
    uint channel = cfa_channel(p.pattern, x, y);
    value = float(codes[index]) / float(p.maximum_code) / p.analog_gain
        * p.saturation[channel];
    return true;
}

kernel void reconstruct_green(device const ushort* codes [[buffer(0)]],
                              device float* green [[buffer(1)]],
                              constant CameraParams& p [[buffer(2)]],
                              uint index [[thread_position_in_grid]]) {
    uint count = p.width * p.height;
    if (index >= count) return;
    int x = int(p.origin_x + index % p.width);
    int y = int(p.origin_y + index / p.width);
    float center;
    mosaic_at(codes, p, x, y, center);
    if (cfa_channel(p.pattern, x, y) == 1) {
        green[index] = center;
        return;
    }
    float left = 0.0f, right = 0.0f, far_left = 0.0f, far_right = 0.0f;
    float up = 0.0f, down = 0.0f, far_up = 0.0f, far_down = 0.0f;
    bool horizontal = mosaic_at(codes, p, x - 1, y, left)
        && mosaic_at(codes, p, x + 1, y, right)
        && mosaic_at(codes, p, x - 2, y, far_left)
        && mosaic_at(codes, p, x + 2, y, far_right);
    bool vertical = mosaic_at(codes, p, x, y - 1, up)
        && mosaic_at(codes, p, x, y + 1, down)
        && mosaic_at(codes, p, x, y - 2, far_up)
        && mosaic_at(codes, p, x, y + 2, far_down);
    float h_estimate = (left + right) * 0.5f + (2.0f * center - far_left - far_right) * 0.25f;
    float v_estimate = (up + down) * 0.5f + (2.0f * center - far_up - far_down) * 0.25f;
    float h_gradient = abs(left - right) + abs(2.0f * center - far_left - far_right);
    float v_gradient = abs(up - down) + abs(2.0f * center - far_up - far_down);
    if (horizontal && vertical) {
        green[index] = h_gradient < v_gradient ? h_estimate
            : (v_gradient < h_gradient ? v_estimate : (h_estimate + v_estimate) * 0.5f);
    } else if (horizontal) {
        green[index] = h_estimate;
    } else if (vertical) {
        green[index] = v_estimate;
    } else {
        float sum = 0.0f;
        float available = 0.0f;
        float value;
        if (mosaic_at(codes, p, x - 1, y, value)) { sum += value; available += 1.0f; }
        if (mosaic_at(codes, p, x + 1, y, value)) { sum += value; available += 1.0f; }
        if (mosaic_at(codes, p, x, y - 1, value)) { sum += value; available += 1.0f; }
        if (mosaic_at(codes, p, x, y + 1, value)) { sum += value; available += 1.0f; }
        green[index] = sum / available;
    }
}

inline bool green_at(device const float* green, constant CameraParams& p,
                     int x, int y, thread float& value) {
    uint index;
    if (!local_index(p, x, y, index)) return false;
    value = green[index];
    return true;
}

inline float interpolate_difference(device const ushort* codes, device const float* green,
                                    constant CameraParams& p, int x, int y,
                                    uint channel, float center_green) {
    int2 offsets[4];
    uint offset_count;
    uint own = cfa_channel(p.pattern, x, y);
    if (own == 1) {
        bool horizontal = cfa_channel(p.pattern, x - 1, y) == channel
            || cfa_channel(p.pattern, x + 1, y) == channel;
        offsets[0] = horizontal ? int2(-1, 0) : int2(0, -1);
        offsets[1] = horizontal ? int2(1, 0) : int2(0, 1);
        offset_count = 2;
    } else {
        offsets[0] = int2(-1, -1); offsets[1] = int2(1, -1);
        offsets[2] = int2(-1, 1); offsets[3] = int2(1, 1);
        offset_count = 4;
    }
    float sum = 0.0f;
    float count = 0.0f;
    for (uint i = 0; i < offset_count; ++i) {
        int sx = x + offsets[i].x;
        int sy = y + offsets[i].y;
        if (cfa_channel(p.pattern, sx, sy) != channel) continue;
        float sample, sample_green;
        if (mosaic_at(codes, p, sx, sy, sample) && green_at(green, p, sx, sy, sample_green)) {
            sum += sample - sample_green;
            count += 1.0f;
        }
    }
    return center_green + sum / count;
}

inline float4 developed_acescg_at(device const ushort* codes,
                                  device const float* green,
                                  constant CameraParams& p,
                                  uint index) {
    int x = int(p.origin_x + index % p.width);
    int y = int(p.origin_y + index / p.width);
    uint own = cfa_channel(p.pattern, x, y);
    float center_green = green[index];
    float own_value;
    mosaic_at(codes, p, x, y, own_value);
    float3 sensor_rgb;
    sensor_rgb.y = center_green;
    sensor_rgb.x = own == 0 ? own_value
        : interpolate_difference(codes, green, p, x, y, 0, center_green);
    sensor_rgb.z = own == 2 ? own_value
        : interpolate_difference(codes, green, p, x, y, 2, center_green);
    sensor_rgb *= p.white_balance.xyz;
    float3 acescg = float3(dot(p.sensor_to_acescg_0.xyz, sensor_rgb),
                           dot(p.sensor_to_acescg_1.xyz, sensor_rgb),
                           dot(p.sensor_to_acescg_2.xyz, sensor_rgb)) * p.linear_scale;
    if (p.rendering_intent.w > 0.5f) {
        acescg *= exp2(p.rendering_intent.x) * p.rendering_white_gains.xyz;
        acescg = float3(signed_contrast(acescg.x, p.rendering_intent.y),
                        signed_contrast(acescg.y, p.rendering_intent.y),
                        signed_contrast(acescg.z, p.rendering_intent.y));
        float luminance = dot(acescg, float3(0.27222872f, 0.67408174f, 0.053689517f));
        acescg = luminance + (acescg - luminance) * p.rendering_intent.z;
    }
    return float4(acescg, 1.0f);
}

kernel void develop_acescg(device const ushort* codes [[buffer(0)]],
                           device const float* green [[buffer(1)]],
                           device float4* output [[buffer(2)]],
                           constant CameraParams& p [[buffer(3)]],
                           uint index [[thread_position_in_grid]]) {
    uint count = p.width * p.height;
    if (index >= count) return;
    output[index] = developed_acescg_at(codes, green, p, index);
}

kernel void develop_acescg_texture(
    device const ushort* codes [[buffer(0)]],
    device const float* green [[buffer(1)]],
    texture2d<float, access::write> output [[texture(0)]],
    constant CameraParams& p [[buffer(2)]],
    uint2 position [[thread_position_in_grid]]) {
    if (position.x >= p.width || position.y >= p.height) return;
    output.write(
        developed_acescg_at(codes, green, p, position.y * p.width + position.x),
        position
    );
}
