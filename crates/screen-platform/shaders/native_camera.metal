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
};

struct SensorExposureParams {
    uint input_width;
    uint input_height;
    uint width;
    uint height;
    uint pattern;
    uint maximum_code;
    long frame_index;
    ulong noise_seed;
    float duration_seconds;
    float full_well_electrons;
    float dark_current_electrons_per_second;
    float read_noise_electrons_rms;
    float analog_gain;
    float noise_amount;
    float4 acescg_to_sensor_0;
    float4 acescg_to_sensor_1;
    float4 acescg_to_sensor_2;
    float4 saturation;
};

inline uint cfa_channel(uint pattern, int x, int y) {
    uint parity = (uint(y & 1) << 1) | uint(x & 1);
    constexpr uint table[4][4] = {
        {0, 1, 1, 2}, {2, 1, 1, 0}, {1, 0, 2, 1}, {1, 2, 0, 1}
    };
    return table[pattern][parity];
}

inline ulong sensor_splitmix64(ulong value) {
    value += 0x9E3779B97F4A7C15ul;
    value = (value ^ (value >> 30)) * 0xBF58476D1CE4E5B9ul;
    value = (value ^ (value >> 27)) * 0x94D049BB133111EBul;
    return value ^ (value >> 31);
}

inline float sensor_uniform(ulong key, ulong sample) {
    const ulong bits = sensor_splitmix64(key ^ sample * 0xA0761D6478BD642Ful) >> 40;
    return (float(bits) + 0.5f) * (1.0f / 16777216.0f);
}

inline float sensor_gaussian(ulong key) {
    float sum = 0.0f;
    for (ulong sample = 0; sample < 12; ++sample) sum += sensor_uniform(key, sample);
    return sum - 6.0f;
}

inline float sensor_poisson(float lambda, ulong key) {
    if (lambda <= 0.0f) return 0.0f;
    if (lambda >= 30.0f) {
        return max(round(lambda + sqrt(lambda) * sensor_gaussian(key)), 0.0f);
    }
    const float threshold = exp(-lambda);
    float product = 1.0f;
    ulong count = 0;
    while (true) {
        product *= sensor_uniform(key, count);
        if (product <= threshold) return float(count);
        ++count;
    }
}

inline float4 sensor_area_sample(texture2d<float, access::read> input, uint2 sensor_position,
                                 constant SensorExposureParams& p) {
    const float2 minimum = float2(sensor_position) * float2(p.input_width, p.input_height)
        / float2(p.width, p.height);
    const float2 maximum = float2(sensor_position + 1) * float2(p.input_width, p.input_height)
        / float2(p.width, p.height);
    float4 sum = 0.0f;
    float area = 0.0f;
    const int2 first = int2(floor(minimum));
    const int2 last = int2(ceil(maximum));
    for (int y = first.y; y < last.y; ++y) {
        const float overlap_y = max(min(maximum.y, float(y + 1)) - max(minimum.y, float(y)), 0.0f);
        for (int x = first.x; x < last.x; ++x) {
            const float overlap_x = max(min(maximum.x, float(x + 1)) - max(minimum.x, float(x)), 0.0f);
            const float weight = overlap_x * overlap_y;
            sum += input.read(uint2(clamp(x, 0, int(p.input_width) - 1),
                                     clamp(y, 0, int(p.input_height) - 1))) * weight;
            area += weight;
        }
    }
    return sum / area;
}

kernel void expose_sensor_raw(texture2d<float, access::read> exposure [[texture(0)]],
                              device ushort* codes [[buffer(0)]],
                              device uchar2* clipping [[buffer(1)]],
                              constant SensorExposureParams& p [[buffer(2)]],
                              uint2 position [[thread_position_in_grid]]) {
    if (position.x >= p.width || position.y >= p.height) return;
    const uint index = position.y * p.width + position.x;
    const float3 acescg = sensor_area_sample(exposure, position, p).rgb;
    const float3 sensor = float3(dot(p.acescg_to_sensor_0.xyz, acescg),
                                dot(p.acescg_to_sensor_1.xyz, acescg),
                                dot(p.acescg_to_sensor_2.xyz, acescg));
    const uint channel = cfa_channel(p.pattern, int(position.x), int(position.y));
    const float native_exposure = max(sensor[channel], 0.0f);
    const float ideal = native_exposure / p.saturation[channel] * p.full_well_electrons;
    const ulong key = p.noise_seed
        ^ ulong(p.frame_index) * 0x9E3779B97F4A7C15ul
        ^ ulong(index) * 0xD1B54A32D192ED03ul;
    const float sampled = sensor_poisson(ideal, key);
    const float photoelectrons = ideal + p.noise_amount * (sampled - ideal);
    const float dark = p.noise_amount * sensor_poisson(
        p.dark_current_electrons_per_second * p.duration_seconds,
        key ^ 0xA0761D6478BD642Ful);
    const float read = p.noise_amount * p.read_noise_electrons_rms
        * sensor_gaussian(key ^ 0xE7037ED1A0B428DBul);
    const float collected = photoelectrons + dark;
    const bool well_clipped = collected >= p.full_well_electrons;
    const float well = clamp(collected, 0.0f, p.full_well_electrons);
    const float normalized = max(well + read, 0.0f) * p.analog_gain / p.full_well_electrons;
    const bool adc_clipped = normalized >= 1.0f;
    codes[index] = ushort(round(clamp(normalized, 0.0f, 1.0f) * float(p.maximum_code)));
    clipping[index] = uchar2(well_clipped, adc_clipped);
}

kernel void publish_sensor_raw(device const ushort* codes [[buffer(0)]],
                               device const uchar2* clipping [[buffer(1)]],
                               texture2d<float, access::write> output [[texture(0)]],
                               constant SensorExposureParams& p [[buffer(2)]],
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

kernel void develop_acescg(device const ushort* codes [[buffer(0)]],
                           device const float* green [[buffer(1)]],
                           device float4* output [[buffer(2)]],
                           constant CameraParams& p [[buffer(3)]],
                           uint index [[thread_position_in_grid]]) {
    uint count = p.width * p.height;
    if (index >= count) return;
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
    output[index] = float4(acescg, 1.0f);
}

kernel void publish_developed_acescg(
    device const float4* input [[buffer(0)]],
    texture2d<float, access::write> output [[texture(0)]],
    constant CameraParams& p [[buffer(1)]],
    uint2 position [[thread_position_in_grid]]) {
    if (position.x >= p.width || position.y >= p.height) return;
    output.write(input[position.y * p.width + position.x], position);
}
