#include <metal_stdlib>
using namespace metal;

struct PhysicalPipelineParams {
    uint4 source_panel; // source width, source height, panel width, panel height
    uint4 output_tile;  // output width, output height, tile origin y, sample side
    uint4 semantics;    // placement, stripe layout, reserved, reserved
    float4 levels;      // gamma, black nits, white nits, temporal calibrated gain
    float4 geometry;    // black matrix fraction, moire saturation, reserved, moire intensity
    float4 strengths;   // screen, emission, subpixel geometry, temporal emission
    float4 matrix0;
    float4 matrix1;
    float4 matrix2;
    float4 panel_size_meters;
    float4 uniformity_amplitudes; // broad, mid, fine, chromatic peak-to-peak
    float4 uniformity_scales; // mid mm, fine mm, low-drive emphasis, character
    uint4 uniformity_seed;
    float4 spread_core_radius;
    float4 spread_core_weight;
    float4 spread_tail_radius;
    float4 spread_tail_weight;
    float4 cover_geometry;
    float4 cover_absorption_roughness;
    float4 cover_haze;
    float4 cover_microtexture; // character, RMS slope, correlation um, anisotropy
    uint4 cover_microtexture_seed;
    float4 cover_glow; // core mm, tail mm, scattered fraction, tail fraction
    float4 environment_ambient_strength;
    float4 environment_key_radius;
    float4 environment_direction;
    float4 environment_rotation; // panel-local X and Y radians
    float4 environment_center; // world-space finite-sphere center in meters
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
    float4 lens_veiling_glare; // fraction, gate/content coverage, facing ratio, reserved
    float4 screen_translation;
    float4 screen_quaternion;
    float4 panel_angular_scene;
    float4 shutter;
};

constant float PI = 3.14159265358979323846f;
constant bool VFX_DEPTH_BLUR [[function_constant(0)]];
constant bool IMAGE_ENVIRONMENT [[function_constant(1)]];

struct EnvironmentImportanceParams {
    uint first_level;
};

kernel void build_environment_importance(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> destination [[texture(1)]],
    constant EnvironmentImportanceParams& params [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]) {
    if (position.x >= destination.get_width() || position.y >= destination.get_height()) return;
    if (params.first_level != 0u) {
        const float4 radiance = source.read(position);
        const float v = (float(position.y) + 0.5f) / float(destination.get_height());
        const float luminance = max(0.0f,
            dot(radiance.rgb, float3(0.2722287f, 0.6740818f, 0.0536895f)));
        destination.write(float4(radiance.rgb, luminance * max(sin(PI * v), 1.0e-8f)), position);
        return;
    }
    const uint2 source_dimensions = uint2(source.get_width(), source.get_height());
    const uint2 destination_dimensions = uint2(
        destination.get_width(), destination.get_height());
    const uint2 begin = position * source_dimensions / destination_dimensions;
    const uint2 end = (position + 1u) * source_dimensions / destination_dimensions;
    float weight = 0.0f;
    for (uint y = begin.y; y < end.y; ++y) {
        for (uint x = begin.x; x < end.x; ++x) {
            weight += source.read(uint2(x, y)).a;
        }
    }
    destination.write(float4(0.0f, 0.0f, 0.0f, weight), position);
}

struct PhysicalRayHit {
    float2 uv;
    float cosine;
    float3 reflection_direction;
    bool valid;
};

struct PhysicalIdealPoint {
    float2 point;
    bool valid;
};

struct PhysicalLensOrigin {
    float3 world;
    float3 screen_local;
};

struct PhysicalRayFootprint {
    PhysicalRayHit hit;
    float2 projected_sensor_half_extent;
    float2 continuous_half_extent;
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
    for (uint iteration = 0; iteration < 12; ++iteration) {
        const float2 projected = physical_distort(ideal, p);
        const float2 residual = observed - projected;
        if (max(abs(residual.x), abs(residual.y)) < 1.0e-6f) return true;
        const float radius2 = dot(ideal, ideal);
        const float radius4 = radius2 * radius2;
        const float k1 = p.lens_shift_radial01.z;
        const float k2 = p.lens_shift_radial01.w;
        const float k3 = p.lens_radial2_tangential.x;
        const float p1 = p.lens_radial2_tangential.y;
        const float p2 = p.lens_radial2_tangential.z;
        const float radial = 1.0f + k1 * radius2 + k2 * radius4 + k3 * radius4 * radius2;
        const float radial_slope = k1 + 2.0f * k2 * radius2 + 3.0f * k3 * radius4;
        const float radial_dx = 2.0f * ideal.x * radial_slope;
        const float radial_dy = 2.0f * ideal.y * radial_slope;
        const float j00 = radial + ideal.x * radial_dx + 2.0f * p1 * ideal.y + 6.0f * p2 * ideal.x;
        const float j01 = ideal.x * radial_dy + 2.0f * p1 * ideal.x + 2.0f * p2 * ideal.y;
        const float j10 = ideal.y * radial_dx + 2.0f * p1 * ideal.x + 2.0f * p2 * ideal.y;
        const float j11 = radial + ideal.y * radial_dy + 6.0f * p1 * ideal.y + 2.0f * p2 * ideal.x;
        const float determinant = j00 * j11 - j01 * j10;
        if (!isfinite(determinant) || determinant <= 1.0e-8f) return false;
        ideal += float2(j11 * residual.x - j01 * residual.y,
            -j10 * residual.x + j00 * residual.y) / determinant;
        if (!all(isfinite(ideal))) return false;
    }
    const float2 residual = physical_distort(ideal, p) - observed;
    return max(abs(residual.x), abs(residual.y)) < 1.0e-5f;
}

// These immutable bit patterns are the exact results of the former Metal
// quadrature formulas. Keeping the GPU-authored values avoids repeating
// trigonometry per pixel without moving optical sample ownership to the CPU.
constant uint2 PHYSICAL_APERTURE_SAMPLE_BITS[32] = {
    uint2(0x3f3504f3, 0x00000000), uint2(0xbebcc434, 0x3eacecf0),
    uint2(0x3d9b0f48, 0xbf5cda86), uint2(0x3e5c474e, 0x3e8fa833),
    uint2(0xbf474ac1, 0xbe0d01ed), uint2(0x3f0445f4, 0xbea8486d),
    uint2(0xbe78aa2d, 0x3f67418c), uint2(0xbdebfc1b, 0xbe632fcb),
    uint2(0x3f345989, 0x3e83ba01), uint2(0xbf044813, 0x3e5a6a7b),
    uint2(0x3ec39bf6, 0xbf5100c5), uint2(0x3e04b43e, 0x3ed38a62),
    uint2(0xbf37a745, 0xbed4dc5e), uint2(0x3f2560e9, 0xbe116ef0),
    uint2(0xbf0e8eb9, 0x3f4ac62e), uint2(0xbcba1b09, 0xbe3384b0),
    uint2(0x3f0ead27, 0x3ef07eb2), uint2(0xbf07a608, 0x3cb38264),
    uint2(0x3f2063be, 0xbf1f9c05), uint2(0xbc95929c, 0x3eca2b75),
    uint2(0xbf04df6f, 0xbf1f39c9), uint2(0x3f21b621, 0x3dae1041),
    uint2(0xbf480c09, 0x3f0b3009), uint2(0x3d89a13b, 0xbe98f1e1),
    uint2(0x3ec42682, 0x3f2b2718), uint2(0xbf0efe35, 0xbe3678e1),
    uint2(0x3f5577b7, 0xbec541c3), uint2(0xbe38e53e, 0x3edce6bf),
    uint2(0xbe92e9c1, 0xbf4c39c8), uint2(0x3f1b2604, 0x3ea31503),
    uint2(0xbf73a542, 0x3e807334), uint2(0x3d8a742d, 0xbdd75433),
};

constant uint2 PHYSICAL_PSF_SAMPLE_BITS[16] = {
    uint2(0xbf07c3b6, 0xbf07c3b6), uint2(0xbe46c5e6, 0xbf397530),
    uint2(0x3e46c5ea, 0xbf39752f), uint2(0x3f07c3b6, 0xbf07c3b6),
    uint2(0xbf397530, 0xbe46c5e5), uint2(0xbe3504f3, 0xbe3504f3),
    uint2(0x3e3504f3, 0xbe3504f3), uint2(0x3f397530, 0xbe46c5e5),
    uint2(0xbf397530, 0x3e46c5e5), uint2(0xbe3504f3, 0x3e3504f3),
    uint2(0x3e3504f3, 0x3e3504f3), uint2(0x3f397530, 0x3e46c5e5),
    uint2(0xbf07c3b6, 0x3f07c3b6), uint2(0xbe46c5ea, 0x3f39752f),
    uint2(0x3e46c5e6, 0x3f397530), uint2(0x3f07c3b6, 0x3f07c3b6),
};

inline float2 physical_aperture_sample(uint index) {
    return as_type<float2>(PHYSICAL_APERTURE_SAMPLE_BITS[index]);
}

inline float2 physical_psf_disk_sample(uint index) {
    return as_type<float2>(PHYSICAL_PSF_SAMPLE_BITS[index]);
}

inline PhysicalRayHit physical_ray_miss() {
    PhysicalRayHit miss;
    miss.uv = 0.0f; miss.cosine = 0.0f; miss.reflection_direction = 0.0f; miss.valid = false;
    return miss;
}

inline PhysicalIdealPoint physical_ideal_point(
    float2 observed,
    constant PhysicalPipelineParams& p
) {
    PhysicalIdealPoint result;
    result.valid = physical_inverse_distortion(
        float2(observed.x + 2.0f * p.lens_shift_radial01.x,
            -observed.y - 2.0f * p.lens_shift_radial01.y),
        p,
        result.point
    );
    return result;
}

inline PhysicalIdealPoint physical_invalid_ideal_point() {
    PhysicalIdealPoint result;
    result.point = 0.0f;
    result.valid = false;
    return result;
}

inline PhysicalLensOrigin physical_lens_origin(
    float2 lens_sample,
    float4 inverse_screen_quaternion,
    constant PhysicalPipelineParams& p
) {
    const float aperture_radius = p.camera_position_focal.w * 0.001f
        / (2.0f * p.camera_limits.x);
    PhysicalLensOrigin result;
    result.world = p.camera_position_focal.xyz
        + p.camera_right_sensor_width.xyz * (lens_sample.x * aperture_radius)
        + p.camera_up_sensor_height.xyz * (lens_sample.y * aperture_radius);
    result.screen_local = physical_quaternion_rotate(
        inverse_screen_quaternion,
        result.world - p.screen_translation.xyz
    );
    return result;
}

inline PhysicalRayHit physical_trace_ray_from_ideal(
    float2 ideal,
    PhysicalLensOrigin lens_origin,
    float4 inverse_screen_quaternion,
    uint channel,
    constant PhysicalPipelineParams& p
) {
    PhysicalRayHit miss = physical_ray_miss();
    ideal *= p.lens_lateral[channel];
    const float3 pinhole = normalize(p.camera_forward_focus.xyz
        + p.camera_right_sensor_width.xyz * (ideal.x * p.camera_right_sensor_width.w
            / (2.0f * p.camera_position_focal.w))
        + p.camera_up_sensor_height.xyz * (ideal.y * p.camera_up_sensor_height.w
            / (2.0f * p.camera_position_focal.w)));
    const float channel_focus = p.camera_forward_focus.w + p.lens_longitudinal[channel];
    const float3 focus_point = p.camera_position_focal.xyz
        + pinhole * (channel_focus / dot(pinhole, p.camera_forward_focus.xyz));
    const float3 ray = normalize(focus_point - lens_origin.world);
    const float3 local_origin = lens_origin.screen_local;
    const float3 local_ray = physical_quaternion_rotate(inverse_screen_quaternion, ray);
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

inline float physical_irradiance_weight_from_ideal(
    float2 ideal,
    uint channel,
    constant PhysicalPipelineParams& p
) {
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

inline PhysicalRayFootprint physical_ray_footprint(
    PhysicalIdealPoint center,
    PhysicalIdealPoint sensor_positive_x,
    PhysicalIdealPoint sensor_negative_x,
    PhysicalIdealPoint sensor_positive_y,
    PhysicalIdealPoint sensor_negative_y,
    PhysicalLensOrigin lens_origin,
    PhysicalLensOrigin sensor_origin,
    PhysicalLensOrigin rim_x_origin,
    PhysicalLensOrigin rim_y_origin,
    float4 inverse_screen_quaternion,
    uint channel,
    float2 half_extent,
    bool vfx_depth_blur,
    constant PhysicalPipelineParams& p
) {
    PhysicalRayFootprint footprint;
    footprint.hit = center.valid
        ? physical_trace_ray_from_ideal(
            center.point, lens_origin, inverse_screen_quaternion, channel, p)
        : physical_ray_miss();
    footprint.projected_sensor_half_extent = half_extent;
    footprint.continuous_half_extent = 0.0f;
    if (!vfx_depth_blur || !footprint.hit.valid) return footprint;

    const PhysicalRayHit positive_x = sensor_positive_x.valid
        ? physical_trace_ray_from_ideal(
            sensor_positive_x.point, sensor_origin, inverse_screen_quaternion, channel, p)
        : physical_ray_miss();
    const PhysicalRayHit negative_x = sensor_negative_x.valid
        ? physical_trace_ray_from_ideal(
            sensor_negative_x.point, sensor_origin, inverse_screen_quaternion, channel, p)
        : physical_ray_miss();
    const PhysicalRayHit positive_y = sensor_positive_y.valid
        ? physical_trace_ray_from_ideal(
            sensor_positive_y.point, sensor_origin, inverse_screen_quaternion, channel, p)
        : physical_ray_miss();
    const PhysicalRayHit negative_y = sensor_negative_y.valid
        ? physical_trace_ray_from_ideal(
            sensor_negative_y.point, sensor_origin, inverse_screen_quaternion, channel, p)
        : physical_ray_miss();
    const float2 sensor_px = positive_x.valid
        ? positive_x.uv - footprint.hit.uv : float2(0.0f);
    const float2 sensor_nx = negative_x.valid
        ? negative_x.uv - footprint.hit.uv : float2(0.0f);
    const float2 sensor_py = positive_y.valid
        ? positive_y.uv - footprint.hit.uv : float2(0.0f);
    const float2 sensor_ny = negative_y.valid
        ? negative_y.uv - footprint.hit.uv : float2(0.0f);
    footprint.projected_sensor_half_extent = float2(
        max(abs(sensor_px.x), abs(sensor_nx.x))
            + max(abs(sensor_py.x), abs(sensor_ny.x)),
        max(abs(sensor_px.y), abs(sensor_nx.y))
            + max(abs(sensor_py.y), abs(sensor_ny.y))
    );
    constexpr float disk_to_box_variance_scale = 0.8660254f;
    const PhysicalRayHit rim_x = physical_trace_ray_from_ideal(
        center.point, rim_x_origin, inverse_screen_quaternion, channel, p);
    const PhysicalRayHit rim_y = physical_trace_ray_from_ideal(
        center.point, rim_y_origin, inverse_screen_quaternion, channel, p);
    const float2 x_uv = rim_x.valid ? rim_x.uv : footprint.hit.uv;
    const float2 y_uv = rim_y.valid ? rim_y.uv : footprint.hit.uv;
    const float2 x_axis = x_uv - footprint.hit.uv;
    const float2 y_axis = y_uv - footprint.hit.uv;
    footprint.continuous_half_extent = sqrt(x_axis * x_axis + y_axis * y_axis)
        * disk_to_box_variance_scale * p.panel_angular_scene.w;
    return footprint;
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

inline float flat_environment_rectangle(float3 direction, float2 center,
                                         float2 half_extent, float softness) {
    return (1.0f - smoothstep(half_extent.x - softness, half_extent.x + softness,
                abs(direction.x - center.x)))
        * (1.0f - smoothstep(half_extent.y - softness, half_extent.y + softness,
                abs(direction.y - center.y)))
        * smoothstep(0.0f, 0.12f, direction.z);
}

inline float flat_environment_circle(float3 direction, float3 center,
                                      float radius_degrees, float softness) {
    const float alignment = clamp(dot(direction, normalize(center)), -1.0f, 1.0f);
    const float edge = cos(radius_degrees * PI / 180.0f);
    return smoothstep(edge - softness, edge + softness, alignment);
}

inline float2 physical_environment_uv(float3 direction) {
    direction = normalize(direction);
    return float2(
        fract(atan2(direction.x, direction.z) / (2.0f * PI) + 0.5f),
        clamp(0.5f - asin(clamp(direction.y, -1.0f, 1.0f)) / PI, 0.0f, 1.0f)
    );
}

inline float physical_radical_inverse_vdc(uint bits) {
    bits = (bits << 16u) | (bits >> 16u);
    bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
    bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
    bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
    bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
    return float(bits) * 2.3283064365386963e-10f;
}

inline uint physical_hash_uint(uint value) {
    value ^= value >> 16u;
    value *= 0x7FEB352Du;
    value ^= value >> 15u;
    value *= 0x846CA68Bu;
    value ^= value >> 16u;
    return value;
}

inline float3 physical_sample_visible_ggx(float3 outgoing, float alpha, float2 sample) {
    const float3 stretched = normalize(float3(alpha * outgoing.xy, outgoing.z));
    const float lensq = dot(stretched.xy, stretched.xy);
    const float3 tangent1 = lensq > 0.0f
        ? float3(-stretched.y, stretched.x, 0.0f) * rsqrt(lensq)
        : float3(1.0f, 0.0f, 0.0f);
    const float3 tangent2 = cross(stretched, tangent1);
    const float radius = sqrt(sample.x);
    const float phi = 2.0f * PI * sample.y;
    const float t1 = radius * cos(phi);
    float t2 = radius * sin(phi);
    const float blend = 0.5f * (1.0f + stretched.z);
    t2 = (1.0f - blend) * sqrt(max(0.0f, 1.0f - t1 * t1)) + blend * t2;
    const float3 normal = t1 * tangent1 + t2 * tangent2
        + sqrt(max(0.0f, 1.0f - t1 * t1 - t2 * t2)) * stretched;
    return normalize(float3(alpha * normal.xy, max(0.0f, normal.z)));
}

inline float physical_smith_ggx_lambda(float3 direction, float alpha) {
    const float cosine_squared = direction.z * direction.z;
    if (cosine_squared <= 1.0e-12f) return INFINITY;
    const float tangent_squared = max(0.0f, 1.0f - cosine_squared) / cosine_squared;
    return 0.5f * (sqrt(1.0f + alpha * alpha * tangent_squared) - 1.0f);
}

inline float physical_ggx_distribution(float3 normal, float alpha) {
    const float alpha_squared = alpha * alpha;
    const float denominator = normal.z * normal.z * (alpha_squared - 1.0f) + 1.0f;
    return alpha_squared / max(PI * denominator * denominator, 1.0e-12f);
}

inline float3 physical_environment_direction(float2 uv) {
    const float longitude = (uv.x - 0.5f) * 2.0f * PI;
    const float latitude = (0.5f - uv.y) * PI;
    const float latitude_cosine = cos(latitude);
    return float3(sin(longitude) * latitude_cosine, sin(latitude),
        cos(longitude) * latitude_cosine);
}

inline float3 physical_environment_to_source(float3 direction, float rotation_x, float rotation_y) {
    const float sine_y = sin(rotation_y);
    const float cosine_y = cos(rotation_y);
    const float3 yawed = float3(
        direction.x * cosine_y + direction.z * sine_y,
        direction.y,
        -direction.x * sine_y + direction.z * cosine_y);
    const float sine_x = sin(rotation_x);
    const float cosine_x = cos(rotation_x);
    return float3(
        yawed.x,
        yawed.y * cosine_x - yawed.z * sine_x,
        yawed.y * sine_x + yawed.z * cosine_x);
}

inline float3 physical_environment_to_local(float3 direction, float rotation_x, float rotation_y) {
    const float sine_x = sin(rotation_x);
    const float cosine_x = cos(rotation_x);
    const float3 unpitched = float3(
        direction.x,
        direction.y * cosine_x + direction.z * sine_x,
        -direction.y * sine_x + direction.z * cosine_x);
    const float sine_y = sin(rotation_y);
    const float cosine_y = cos(rotation_y);
    return float3(
        unpitched.x * cosine_y - unpitched.z * sine_y,
        unpitched.y,
        unpitched.x * sine_y + unpitched.z * cosine_y);
}

inline float physical_environment_pdf(float2 uv,
    texture2d<float, access::sample> environment,
    uint2 dimensions,
    float total) {
    const uint2 texel = min(uint2(uv * float2(dimensions)), dimensions - 1u);
    const float weight = environment.read(texel, 0u).a;
    const float sine_theta = max(sin(PI * uv.y), 1.0e-8f);
    return weight * float(dimensions.x * dimensions.y)
        / max(total * 2.0f * PI * PI * sine_theta, 1.0e-12f);
}

inline float3 physical_sample_environment(float selector, float2 jitter,
    texture2d<float, access::sample> environment,
    uint top_level,
    float total) {
    uint2 parent = uint2(0u);
    float residual = selector * total;
    for (uint level = top_level; level > 0u; --level) {
        const uint child_level = level - 1u;
        const uint2 child_dimensions = uint2(
            max(1u, environment.get_width() >> child_level),
            max(1u, environment.get_height() >> child_level));
        const uint2 parent_dimensions = uint2(
            max(1u, environment.get_width() >> level),
            max(1u, environment.get_height() >> level));
        const uint2 begin = parent * child_dimensions / parent_dimensions;
        const uint2 end = (parent + 1u) * child_dimensions / parent_dimensions;
        uint2 selected = min(begin, child_dimensions - 1u);
        bool selected_child = false;
        for (uint y = begin.y; y < end.y && !selected_child; ++y) {
            for (uint x = begin.x; x < end.x; ++x) {
                const uint2 child = uint2(x, y);
                const float weight = environment.read(child, child_level).a;
                if (residual <= weight) {
                    selected = child;
                    selected_child = true;
                    break;
                }
                residual -= weight;
            }
        }
        parent = selected;
    }
    const float2 uv = (float2(parent) + jitter)
        / float2(environment.get_width(), environment.get_height());
    return physical_environment_direction(uv);
}

inline float3 physical_finite_sphere_incident(float3 source_direction,
    float3 cover_position, float3 center, float radius, thread float& jacobian) {
    const float3 origin = cover_position;
    const float3 relative_origin = origin - center;
    const float3 point = center + source_direction * radius;
    const float3 delta = point - origin;
    const float distance = length(delta);
    jacobian = radius * radius * max(1.0e-8f, radius - dot(relative_origin, source_direction))
        / max(1.0e-8f, distance * distance * distance);
    return delta / max(distance, 1.0e-8f);
}

inline float3 physical_finite_sphere_source(float3 incident,
    float3 cover_position, float3 center, float radius, thread float& jacobian) {
    const float3 origin = cover_position - center;
    const float b = dot(origin, incident);
    const float t = -b + sqrt(max(0.0f,
        b * b - (dot(origin, origin) - radius * radius)));
    const float3 source = normalize(origin + incident * t);
    float ignored;
    physical_finite_sphere_incident(source, cover_position, center, radius, ignored);
    jacobian = ignored;
    return source;
}

inline float physical_dielectric_fresnel(float cosine_i, float eta) {
    if (eta == 1.0f) return 0.0f;
    cosine_i = clamp(cosine_i, 0.0f, 1.0f);
    const float sine_t2 = (1.0f - cosine_i * cosine_i) / (eta * eta);
    const float cosine_t = sqrt(max(0.0f, 1.0f - sine_t2));
    const float rs = (cosine_i - eta * cosine_t)
        / max(1.0e-8f, cosine_i + eta * cosine_t);
    const float rp = (eta * cosine_i - cosine_t)
        / max(1.0e-8f, eta * cosine_i + cosine_t);
    return 0.5f * (rs * rs + rp * rp);
}

inline float physical_microtexture_height(int2 lattice, uint octave, uint seed) {
    const uint coordinates = uint(lattice.x) * 0x8DA6B343u
        ^ uint(lattice.y) * 0xD8163841u
        ^ octave * 0xCB1AB31Fu
        ^ seed;
    return float(physical_hash_uint(coordinates)) * 4.656612873077393e-10f - 1.0f;
}

inline float physical_microtexture_visibility(float2 cover_position_meters,
    float2 footprint_half_extent_meters, constant PhysicalPipelineParams& p) {
    const float effective_slope = p.cover_microtexture.x * p.cover_microtexture.y;
    if (effective_slope == 0.0f) return 1.0f;
    const float correlation_length = p.cover_microtexture.z * 1.0e-6f;
    constexpr float cell_ratios[3] = { 1.0f, 0.47f, 0.22f };
    constexpr float amplitudes[3] = { 1.0f, 0.46f, 0.21f };
    float population = 0.0f;
    float normalization = 0.0f;
    const float footprint = length(footprint_half_extent_meters);
    for (uint octave = 0u; octave < 3u; ++octave) {
        const float cell = correlation_length * cell_ratios[octave];
        const float amplitude = amplitudes[octave];
        const float2 anisotropic_cell = float2(
            cell * (1.0f + p.cover_microtexture.w), cell);
        const float2 position = cover_position_meters / anisotropic_cell;
        const int2 lattice = int2(floor(position));
        const float2 fraction = position - float2(lattice);
        const float2 fade = fraction * fraction * (3.0f - 2.0f * fraction);
        const float h00 = physical_microtexture_height(
            lattice, octave, p.cover_microtexture_seed.x);
        const float h10 = physical_microtexture_height(
            lattice + int2(1, 0), octave, p.cover_microtexture_seed.x);
        const float h01 = physical_microtexture_height(
            lattice + int2(0, 1), octave, p.cover_microtexture_seed.x);
        const float h11 = physical_microtexture_height(
            lattice + int2(1, 1), octave, p.cover_microtexture_seed.x);
        const float lower = mix(h00, h10, fade.x);
        const float upper = mix(h01, h11, fade.x);
        const float value = mix(lower, upper, fade.y);
        const float filtered = rsqrt(1.0f + (footprint / cell) * (footprint / cell));
        population += value * filtered * amplitude;
        normalization += amplitude;
    }
    const float contrast = clamp(effective_slope * 24.0f, 0.0f, 0.85f);
    return clamp(1.0f + contrast * population / normalization, 0.15f, 1.85f);
}

inline float3 physical_reference_ggx_environment(
    float3 reflection_direction,
    float2 cover_position_meters,
    texture2d<float, access::sample> environment,
    float rotation_x,
    float rotation_y,
    float view_cosine,
    uint2 sample_seed,
    constant PhysicalPipelineParams& p
) {
    constexpr sampler environment_sampler(
        coord::normalized, s_address::repeat, t_address::clamp_to_edge,
        filter::linear, mip_filter::none
    );
    const float roughness = p.cover_absorption_roughness.w;
    float3 mirror = normalize(reflection_direction);
    const float3 cover_position_world = p.screen_translation.xyz
        + physical_quaternion_rotate(
            p.screen_quaternion, float3(cover_position_meters, 0.0f));
    const float4 inverse_screen_quaternion = float4(
        -p.screen_quaternion.xyz, p.screen_quaternion.w);
    if (roughness <= 0.0f || p.cover_geometry.z == 1.0f) {
        mirror = physical_quaternion_rotate(p.screen_quaternion, mirror);
        if (p.environment_rotation.z > 0.5f) {
            const float3 origin = cover_position_world - p.environment_center.xyz;
            const float radius = p.environment_rotation.w;
            const float b = dot(origin, mirror);
            const float discriminant = b * b - (dot(origin, origin) - radius * radius);
            if (discriminant > 0.0f) {
                mirror = normalize(origin + mirror * (-b + sqrt(discriminant)));
            }
        }
        mirror = physical_environment_to_source(mirror, rotation_x, rotation_y);
        return environment.sample(
            environment_sampler, physical_environment_uv(mirror), level(0.0f)).rgb;
    }
    const float normal_sign = mirror.z >= 0.0f ? 1.0f : -1.0f;
    const float3 canonical_mirror = float3(
        mirror.x, mirror.y * normal_sign, mirror.z * normal_sign);
    const float3 outgoing = float3(
        -canonical_mirror.x, -canonical_mirror.y, canonical_mirror.z);
    const float alpha = max(roughness * roughness, 1.0e-4f);
    const float smooth_fresnel = max(
        physical_dielectric_fresnel(view_cosine, p.cover_geometry.z), 1.0e-8f);
    const float lambda_outgoing = physical_smith_ggx_lambda(outgoing, alpha);
    const uint sample_count = max(2u, uint(p.environment_key_radius.w));
    const uint pair_count = sample_count / 2u;
    const uint2 environment_dimensions = uint2(
        environment.get_width(), environment.get_height());
    const uint environment_top_level = environment.get_num_mip_levels() - 1u;
    const float environment_total = environment.read(
        uint2(0u), environment_top_level).a;
    const float2 shift = float2(
        physical_hash_uint(sample_seed.x ^ (sample_seed.y * 0x9E3779B9u)),
        physical_hash_uint(sample_seed.y ^ (sample_seed.x * 0x85EBCA6Bu)))
        * 2.3283064365386963e-10f;
    float3 sum = float3(0.0f);
    for (uint pair = 0u; pair < pair_count; ++pair) {
        const uint source_index = pair * 2u;
        const float2 random_sample = fract(float2(
            (float(pair) + 0.5f) / float(max(1u, pair_count)),
            physical_radical_inverse_vdc(pair)) + shift);
        const uint random = physical_hash_uint(source_index);
        const float2 jitter = float2(
            physical_hash_uint(random ^ sample_seed.x ^ 0x63D83595u),
            physical_hash_uint(random ^ sample_seed.y ^ 0xB5297A4Du))
            * 2.3283064365386963e-10f;
        {
            const float3 source_direction = physical_sample_environment(
                random_sample.x, jitter, environment,
                environment_top_level, environment_total);
            const float3 source_direction_world = physical_environment_to_local(
                source_direction, rotation_x, rotation_y);
            float sphere_jacobian = 1.0f;
            const float3 incident_world = p.environment_rotation.z > 0.5f
                ? physical_finite_sphere_incident(source_direction_world, cover_position_world,
                    p.environment_center.xyz, p.environment_rotation.w, sphere_jacobian)
                : source_direction_world;
            const float3 rotated_incident = physical_quaternion_rotate(
                inverse_screen_quaternion, incident_world);
            const float3 incident = float3(
                rotated_incident.x,
                rotated_incident.y * normal_sign,
                rotated_incident.z * normal_sign);
            if (incident.z > 0.0f) {
                const float3 micro_normal = normalize(outgoing + incident);
                const float outgoing_dot_micro = max(0.0f, dot(outgoing, micro_normal));
                if (outgoing_dot_micro > 0.0f && micro_normal.z > 0.0f) {
                    const float lambda_incident = physical_smith_ggx_lambda(incident, alpha);
                    const float distribution = physical_ggx_distribution(micro_normal, alpha);
                    const float masking = 1.0f / (1.0f + lambda_outgoing + lambda_incident);
                    const float2 source_uv = physical_environment_uv(source_direction);
                    const float environment_pdf = physical_environment_pdf(
                        source_uv, environment, environment_dimensions, environment_total)
                        / max(sphere_jacobian, 1.0e-8f);
                    const float ggx_pdf = distribution
                        / (4.0f * max(outgoing.z * (1.0f + lambda_outgoing), 1.0e-12f));
                    const float mixture_pdf = 0.5f * (environment_pdf + ggx_pdf);
                    const float weight = physical_dielectric_fresnel(
                        outgoing_dot_micro, p.cover_geometry.z) * distribution * masking
                        / (4.0f * max(outgoing.z, 1.0e-6f) * smooth_fresnel
                            * max(mixture_pdf, 1.0e-12f));
                    sum += environment.sample(
                        environment_sampler, source_uv, level(0.0f)).rgb * weight;
                }
            }
        }
        {
            const float3 sampled_normal = physical_sample_visible_ggx(
                outgoing, alpha, random_sample);
            const float3 incident = reflect(-outgoing, sampled_normal);
            const float3 incident_screen = float3(
                incident.x, incident.y * normal_sign, incident.z * normal_sign);
            const float3 incident_world = physical_quaternion_rotate(
                p.screen_quaternion, incident_screen);
            float sphere_jacobian = 1.0f;
            const float3 source_direction_world = p.environment_rotation.z > 0.5f
                ? physical_finite_sphere_source(incident_world,
                    cover_position_world, p.environment_center.xyz,
                    p.environment_rotation.w, sphere_jacobian)
                : incident_world;
            const float3 source_direction = physical_environment_to_source(
                source_direction_world, rotation_x, rotation_y);
            if (incident.z > 0.0f) {
                const float3 micro_normal = normalize(outgoing + incident);
                const float outgoing_dot_micro = max(0.0f, dot(outgoing, micro_normal));
                if (outgoing_dot_micro > 0.0f && micro_normal.z > 0.0f) {
                    const float lambda_incident = physical_smith_ggx_lambda(incident, alpha);
                    const float distribution = physical_ggx_distribution(micro_normal, alpha);
                    const float masking = 1.0f / (1.0f + lambda_outgoing + lambda_incident);
                    const float2 source_uv = physical_environment_uv(source_direction);
                    const float environment_pdf = physical_environment_pdf(
                        source_uv, environment, environment_dimensions, environment_total)
                        / max(sphere_jacobian, 1.0e-8f);
                    const float ggx_pdf = distribution
                        / (4.0f * max(outgoing.z * (1.0f + lambda_outgoing), 1.0e-12f));
                    const float mixture_pdf = 0.5f * (environment_pdf + ggx_pdf);
                    const float weight = physical_dielectric_fresnel(
                        outgoing_dot_micro, p.cover_geometry.z) * distribution * masking
                        / (4.0f * max(outgoing.z, 1.0e-6f) * smooth_fresnel
                            * max(mixture_pdf, 1.0e-12f));
                    sum += environment.sample(
                        environment_sampler, source_uv, level(0.0f)).rgb * weight;
                }
            }
        }
    }
    return sum / float(sample_count);
}

inline float3 flat_environment_radiance(float3 reflection_direction_local,
    float2 cover_position_meters,
    texture2d<float, access::sample> environment_acescg,
    float view_cosine,
    uint2 sample_seed,
    constant PhysicalPipelineParams& p) {
    float3 direction = normalize(reflection_direction_local);
    const float rotation_x = p.environment_rotation.x;
    const float rotation_y = p.environment_rotation.y;
    if (IMAGE_ENVIRONMENT) {
        return physical_reference_ggx_environment(
            direction, cover_position_meters, environment_acescg,
            rotation_x, rotation_y, view_cosine, sample_seed, p)
            * p.environment_ambient_strength.x * p.environment_ambient_strength.w;
    }
    direction = physical_environment_to_source(direction, rotation_x, rotation_y);
    const float alignment = clamp(dot(direction, p.environment_direction.xyz), -1.0f, 1.0f);
    const float edge = cos(p.environment_key_radius.w);
    const float softness = 0.005f + p.cover_absorption_roughness.w * 0.35f;
    const float key_amount = smoothstep(edge - softness, edge + softness, alignment);
    float pattern_amount = 0.0f;
    float pattern_mean = 0.0f;
    if (p.semantics.w == 1) {
        const float large = flat_environment_rectangle(direction, float2(-0.48f, 0.02f),
            float2(0.30f, 0.42f), softness);
        const float top = flat_environment_rectangle(direction, float2(0.18f, 0.68f),
            float2(0.46f, 0.16f), softness);
        pattern_amount = min(1.0f, large + top * 0.55f + key_amount * 0.08f);
        pattern_mean = 0.14f;
    } else if (p.semantics.w == 2) {
        const float u = atan2(direction.x, direction.z) / (2.0f * PI) + 0.5f;
        const float v = asin(direction.y) / PI + 0.5f;
        const float longitude = abs(fract(u * 24.0f) - 0.5f);
        const float latitude = abs(fract(v * 12.0f) - 0.5f);
        const float lines = longitude > 0.46f || latitude > 0.43f ? 1.0f : 0.0f;
        pattern_amount = max(lines, pow(2.0f, clamp(floor(u * 8.0f), 0.0f, 7.0f) - 7.0f));
        pattern_mean = 0.19f;
    } else if (p.semantics.w == 3) {
        const float left = flat_environment_rectangle(direction, float2(-0.56f, 0.72f),
            float2(0.18f, 0.055f), softness);
        const float center = flat_environment_rectangle(direction, float2(0.0f, 0.72f),
            float2(0.18f, 0.055f), softness);
        const float right = flat_environment_rectangle(direction, float2(0.56f, 0.72f),
            float2(0.18f, 0.055f), softness);
        pattern_amount = min(1.0f, left + center + right + key_amount * 0.12f);
        pattern_mean = 0.045f;
    } else if (p.semantics.w == 4) {
        const float window = flat_environment_rectangle(direction, float2(-0.58f, 0.12f),
            float2(0.28f, 0.52f), softness);
        const float sky = flat_environment_rectangle(direction, float2(0.18f, 0.78f),
            float2(0.68f, 0.08f), softness);
        pattern_amount = min(1.0f, window + sky * 0.12f + key_amount * 0.18f);
        pattern_mean = 0.12f;
    } else if (p.semantics.w == 5) {
        const float upper = flat_environment_circle(direction, float3(-0.34f, 0.46f, 0.82f),
            5.0f, softness);
        const float side = flat_environment_circle(direction, float3(0.64f, 0.10f, 0.76f),
            4.0f, softness);
        pattern_amount = min(1.0f, key_amount + upper * 0.62f + side * 0.45f);
        pattern_mean = 0.025f;
    } else if (p.semantics.w == 6) {
        const float softbox = flat_environment_rectangle(direction, float2(-0.50f, 0.16f),
            float2(0.30f, 0.38f), softness);
        const float ceiling = flat_environment_rectangle(direction, float2(0.12f, 0.76f),
            float2(0.58f, 0.08f), softness);
        pattern_amount = min(1.0f, softbox * 0.72f + ceiling * 0.18f + key_amount);
        pattern_mean = 0.11f;
    }
    const float redistribution = clamp(p.cover_absorption_roughness.w * 0.75f
        + p.cover_haze.x * 0.25f, 0.0f, 1.0f);
    pattern_amount = mix(pattern_amount, pattern_mean, redistribution);
    return (p.environment_ambient_strength.xyz + p.environment_key_radius.xyz * pattern_amount)
        * p.environment_ambient_strength.w;
}

inline float3 apply_flat_cover(float3 emitted, float view_cosine,
    float3 reflection_direction_local, float3 lens_irradiance_weight,
    float2 cover_position_meters, float2 footprint_half_extent_meters,
    texture2d<float, access::sample> environment_acescg,
    uint2 sample_seed,
    constant PhysicalPipelineParams& p) {
    const float reflection_visibility = physical_microtexture_visibility(
        cover_position_meters, footprint_half_extent_meters, p);
    const float reflection_cosine = clamp(view_cosine, 0.0f, 1.0f);
    const float transmission_cosine_i = reflection_cosine;
    const float reflection = cover_interface(reflection_cosine, p);
    // Match the CPU cover evaluator: attenuation travels through the oblique
    // slab path, not merely its normal thickness.  The interface and this
    // Beer-Lambert path share the same Snell cosine.
    const float eta = p.cover_geometry.z;
    const float sine_t2 = (1.0f - transmission_cosine_i * transmission_cosine_i)
        / (eta * eta);
    const float cosine_t = sqrt(max(0.0f, 1.0f - sine_t2));
    const float absorption_scale = p.cover_geometry.y * p.cover_geometry.x
        / max(0.01f, cosine_t);
    const float haze_loss = clamp(p.cover_haze.x * p.cover_geometry.x, 0.0f, 0.95f);
    const float3 transmission = (1.0f - reflection)
        * exp(-p.cover_absorption_roughness.xyz * absorption_scale) * (1.0f - haze_loss);
    return emitted * transmission
        + flat_environment_radiance(
            reflection_direction_local, cover_position_meters, environment_acescg,
            reflection_cosine, sample_seed, p) * reflection
            * reflection_visibility
            * lens_irradiance_weight / p.levels.z;
}

inline float3 flat_cover_transmission(float view_cosine,
    constant PhysicalPipelineParams& p) {
    const float cosine_i = clamp(view_cosine, 0.0f, 1.0f);
    const float reflection = cover_interface(cosine_i, p);
    const float eta = p.cover_geometry.z;
    const float sine_t2 = (1.0f - cosine_i * cosine_i) / (eta * eta);
    const float cosine_t = sqrt(max(0.0f, 1.0f - sine_t2));
    const float absorption_scale = p.cover_geometry.y * p.cover_geometry.x
        / max(0.01f, cosine_t);
    const float haze_loss = clamp(p.cover_haze.x * p.cover_geometry.x, 0.0f, 0.95f);
    return (1.0f - reflection)
        * exp(-p.cover_absorption_roughness.xyz * absorption_scale) * (1.0f - haze_loss);
}

inline float panel_rectangle_coverage(float2 position_meters,
    float2 footprint_half_extent_meters, constant PhysicalPipelineParams& p) {
    const float2 panel_half_extent = 0.5f * p.panel_size_meters.xy;
    float2 coverage;
    for (uint axis = 0; axis < 2; ++axis) {
        const float footprint = footprint_half_extent_meters[axis];
        if (footprint <= 1.0e-9f) {
            coverage[axis] = abs(position_meters[axis]) <= panel_half_extent[axis]
                ? 1.0f : 0.0f;
        } else {
            const float footprint_minimum = position_meters[axis] - footprint;
            const float footprint_maximum = position_meters[axis] + footprint;
            const float overlap = max(0.0f,
                min(footprint_maximum, panel_half_extent[axis])
                    - max(footprint_minimum, -panel_half_extent[axis]));
            coverage[axis] = clamp(overlap / (2.0f * footprint), 0.0f, 1.0f);
        }
    }
    return coverage.x * coverage.y;
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
    texture2d<float, access::read> row_prefix,
    float2 device_minimum,
    float2 device_maximum,
    float2 prepared_placement_scale,
    constant PhysicalPipelineParams& p
) {
    const float2 source_size = float2(p.source_panel.xy);
    float2 minimum = ((device_minimum - 0.5f) * prepared_placement_scale + 0.5f)
        * source_size;
    float2 maximum = ((device_maximum - 0.5f) * prepared_placement_scale + 0.5f)
        * source_size;
    minimum = min(minimum, maximum);
    maximum = max(minimum, maximum);
    const float area = max((maximum.x - minimum.x) * (maximum.y - minimum.y), 1.0e-12f);
    const float clipped_minimum_x = clamp(minimum.x, 0.0f, source_size.x);
    const float clipped_maximum_x = clamp(maximum.x, 0.0f, source_size.x);
    const int first_x = int(floor(clipped_minimum_x));
    const int last_x = int(floor(clipped_maximum_x));
    const int first_y = int(floor(minimum.y));
    const int last_y = int(ceil(maximum.y));
    float4 sum = 0.0f;
    for (int y = first_y; y < last_y; ++y) {
        if (y < 0 || y >= int(p.source_panel.y)) continue;
        const float wy = max(0.0f, min(maximum.y, float(y + 1)) - max(minimum.y, float(y)));
        if (wy == 0.0f || clipped_maximum_x <= clipped_minimum_x) continue;
        float4 horizontal = 0.0f;
        if (first_x == last_x) {
            if (first_x >= 0 && first_x < int(p.source_panel.x)) {
                horizontal = texture.read(uint2(first_x, y))
                    * (clipped_maximum_x - clipped_minimum_x);
            }
        } else {
            if (first_x >= 0 && first_x < int(p.source_panel.x)) {
                horizontal += texture.read(uint2(first_x, y))
                    * (float(first_x + 1) - clipped_minimum_x);
            }
            const int interior_begin = max(first_x + 1, 0);
            const int interior_end = min(last_x, int(p.source_panel.x));
            if (interior_end > interior_begin) {
                horizontal += row_prefix.read(uint2(interior_end, y))
                    - row_prefix.read(uint2(interior_begin, y));
            }
            if (last_x >= 0 && last_x < int(p.source_panel.x)) {
                horizontal += texture.read(uint2(last_x, y))
                    * (clipped_maximum_x - float(last_x));
            }
        }
        sum += horizontal * wy;
    }
    return sum / area;
}

kernel void build_physical_row_prefix(
    texture2d<float, access::read> source [[texture(0)]],
    texture2d<float, access::write> prefix [[texture(1)]],
    uint row [[thread_position_in_grid]]
) {
    if (row >= source.get_height()) return;
    float4 accumulated = 0.0f;
    prefix.write(accumulated, uint2(0, row));
    for (uint x = 0; x < source.get_width(); ++x) {
        accumulated += source.read(uint2(x, row));
        prefix.write(accumulated, uint2(x + 1, row));
    }
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

inline float panel_linear_channel(float code, constant PhysicalPipelineParams& p) {
    const float span = p.levels.z - p.levels.y;
    return p.levels.y + span * sign(code) * pow(abs(code), p.levels.x);
}

inline float panel_uniformity_hash(uint value) {
    value ^= value >> 16;
    value *= 0x7FEB352Du;
    value ^= value >> 15;
    value *= 0x846CA68Bu;
    value ^= value >> 16;
    return float(value) / float(0xFFFFFFFFu);
}

inline float panel_uniformity_lattice(int x, int y, uint seed) {
    const uint key = uint(x) * 0x1F123BB5u ^ uint(y) * 0x5F356495u ^ seed;
    return panel_uniformity_hash(key) * 2.0f - 1.0f;
}

inline float panel_uniformity_noise(float x, float y, uint seed) {
    const int ix = int(floor(x));
    const int iy = int(floor(y));
    const float fx = x - float(ix);
    const float fy = y - float(iy);
    const float sx = fx * fx * (3.0f - 2.0f * fx);
    const float sy = fy * fy * (3.0f - 2.0f * fy);
    const float a = panel_uniformity_lattice(ix, iy, seed);
    const float b = panel_uniformity_lattice(ix + 1, iy, seed);
    const float c = panel_uniformity_lattice(ix, iy + 1, seed);
    const float d = panel_uniformity_lattice(ix + 1, iy + 1, seed);
    const float lower = mix(a, b, sx);
    const float upper = mix(c, d, sx);
    return mix(lower, upper, sy);
}

inline float panel_uniformity_filtered_noise(
    float2 uv,
    float2 footprint_millimeters,
    float scale_millimeters,
    uint seed,
    constant PhysicalPipelineParams& p
) {
    const float2 panel_millimeters = p.panel_size_meters.xy * 1000.0f;
    const float2 point = uv * panel_millimeters / scale_millimeters;
    const float2 mirror = (1.0f - uv) * panel_millimeters / scale_millimeters;
    const float footprint = max(footprint_millimeters.x, footprint_millimeters.y);
    const float ratio = footprint / scale_millimeters;
    const float attenuation = 1.0f / (1.0f + ratio * ratio);
    return (panel_uniformity_noise(point.x, point.y, seed)
        - panel_uniformity_noise(mirror.x, mirror.y, seed)) * 0.5f * attenuation;
}

inline float3 panel_uniformity_gains(
    float2 device_minimum,
    float2 device_maximum,
    float3 code,
    constant PhysicalPipelineParams& p
) {
    if (p.uniformity_scales.w == 0.0f) return 1.0f;
    const float2 panel_pixels = float2(p.source_panel.zw);
    const float2 uv = (device_minimum + device_maximum) * 0.5f / panel_pixels;
    const float2 footprint_millimeters = abs(device_maximum - device_minimum)
        / panel_pixels * p.panel_size_meters.xy * 1000.0f;
    const float2 centered = clamp(uv, 0.0f, 1.0f) - 0.5f;
    const float broad = 2.0f * (1.0f / 6.0f
        - centered.x * centered.x - centered.y * centered.y);
    const uint seed = p.uniformity_seed.x;
    const float mid = panel_uniformity_filtered_noise(
        uv, footprint_millimeters, p.uniformity_scales.x, seed, p);
    const float fine = panel_uniformity_filtered_noise(
        uv, footprint_millimeters, p.uniformity_scales.y, seed ^ 0x9E3779B9u, p);
    const float luminance = dot(p.uniformity_amplitudes.xyz, float3(broad, mid, fine));
    const float chroma = p.uniformity_amplitudes.w;
    const float3 opponent = chroma * float3(
        0.5f * mid - 0.25f * fine,
        -0.5f * mid - 0.25f * fine,
        0.5f * fine);
    const float3 drive = clamp(abs(code), 0.0f, 1.0f);
    const float3 drive_scale = 1.0f + p.uniformity_scales.z * (1.0f - drive) * (1.0f - drive);
    return 1.0f + p.uniformity_scales.w * drive_scale * (luminance + opponent);
}

inline float native_channel_from_linear(
    float linear,
    uint channel,
    float2 device_minimum,
    float2 device_maximum,
    constant PhysicalPipelineParams& p
) {
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

inline float native_channel(
    float code,
    uint channel,
    float2 device_minimum,
    float2 device_maximum,
    constant PhysicalPipelineParams& p
) {
    return native_channel_from_linear(
        panel_linear_channel(code, p), channel, device_minimum, device_maximum, p);
}

inline float continuous_channel(float code, constant PhysicalPipelineParams& p) {
    return panel_linear_channel(code, p);
}

inline float native_channel_at_offset(
    texture2d<float, access::read> device_signal,
    texture2d<float, access::read> device_row_prefix,
    uint channel,
    float2 device_minimum,
    float2 device_maximum,
    float2 offset_uv,
    float2 prepared_placement_scale,
    constant PhysicalPipelineParams& p
) {
    const float2 shifted_minimum = device_minimum + offset_uv;
    const float2 shifted_maximum = device_maximum + offset_uv;
    const float4 code = area_sample(
        device_signal, device_row_prefix, shifted_minimum, shifted_maximum,
        prepared_placement_scale, p);
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
    texture2d<float, access::read> device_row_prefix,
    uint channel,
    float2 device_minimum,
    float2 device_maximum,
    float base_native,
    float2 prepared_placement_scale,
    constant PhysicalPipelineParams& p
) {
    const float strength = p.spread_core_radius.w;
    if (strength == 0.0f) {
        return base_native;
    }
    const float core_weight = p.spread_core_weight[channel];
    const float tail_weight = p.spread_tail_weight[channel];
    const float2 inverse_panel = 1.0f / p.panel_size_meters.xy;
    const float core = p.spread_core_radius[channel] * strength * 1.0e-6f;
    const float tail = p.spread_tail_radius[channel] * strength * 0.7071067811865475f * 1.0e-6f;
    float value = base_native * (1.0f - core_weight - tail_weight);
    const float core_sample = core_weight * 0.25f;
    const float tail_sample = tail_weight * 0.25f;
    value += native_channel_at_offset(device_signal, device_row_prefix, channel, device_minimum, device_maximum, float2(core, 0.0f) * inverse_panel, prepared_placement_scale, p) * core_sample;
    value += native_channel_at_offset(device_signal, device_row_prefix, channel, device_minimum, device_maximum, float2(-core, 0.0f) * inverse_panel, prepared_placement_scale, p) * core_sample;
    value += native_channel_at_offset(device_signal, device_row_prefix, channel, device_minimum, device_maximum, float2(0.0f, core) * inverse_panel, prepared_placement_scale, p) * core_sample;
    value += native_channel_at_offset(device_signal, device_row_prefix, channel, device_minimum, device_maximum, float2(0.0f, -core) * inverse_panel, prepared_placement_scale, p) * core_sample;
    value += native_channel_at_offset(device_signal, device_row_prefix, channel, device_minimum, device_maximum, float2(tail, tail) * inverse_panel, prepared_placement_scale, p) * tail_sample;
    value += native_channel_at_offset(device_signal, device_row_prefix, channel, device_minimum, device_maximum, float2(-tail, tail) * inverse_panel, prepared_placement_scale, p) * tail_sample;
    value += native_channel_at_offset(device_signal, device_row_prefix, channel, device_minimum, device_maximum, float2(tail, -tail) * inverse_panel, prepared_placement_scale, p) * tail_sample;
    value += native_channel_at_offset(device_signal, device_row_prefix, channel, device_minimum, device_maximum, float2(-tail, -tail) * inverse_panel, prepared_placement_scale, p) * tail_sample;
    return value;
}

inline float cover_glow_native_channel(
    texture2d<float, access::read> device_signal,
    texture2d<float, access::read> device_row_prefix,
    uint channel,
    float2 device_minimum,
    float2 device_maximum,
    float base_native,
    float2 prepared_placement_scale,
    thread float& exterior_scattered,
    constant PhysicalPipelineParams& p
) {
    const float scattered = p.cover_glow.z;
    if (scattered == 0.0f) {
        exterior_scattered = 0.0f;
        return spread_native_channel(
            device_signal, device_row_prefix, channel, device_minimum, device_maximum,
            base_native, prepared_placement_scale, p);
    }
    const float2 inverse_panel = 1.0f / p.panel_size_meters.xy;
    const float2 core_extent = p.cover_glow.x * 0.001f * inverse_panel;
    const float2 tail_extent = p.cover_glow.y * 0.001f * inverse_panel;
    const float base = spread_native_channel(
        device_signal, device_row_prefix, channel, device_minimum, device_maximum,
        base_native, prepared_placement_scale, p);
    const float core_blur = native_channel_at_offset(
        device_signal, device_row_prefix, channel,
        device_minimum - core_extent, device_maximum + core_extent, float2(0.0f),
        prepared_placement_scale, p);
    const float tail_blur = native_channel_at_offset(
        device_signal, device_row_prefix, channel,
        device_minimum - tail_extent, device_maximum + tail_extent, float2(0.0f),
        prepared_placement_scale, p);
    exterior_scattered = core_blur * scattered * (1.0f - p.cover_glow.w)
        + tail_blur * scattered * p.cover_glow.w;
    return base * (1.0f - scattered) + exterior_scattered;
}

kernel void reduce_physical_veiling_source(
    texture2d<float, access::read> device_signal [[texture(0)]],
    device float4* partials [[buffer(0)]],
    constant PhysicalPipelineParams& p [[buffer(1)]],
    uint index [[thread_position_in_grid]]
) {
    constexpr uint partial_count = 256;
    if (index >= partial_count) return;
    const uint pixel_count = p.source_panel.x * p.source_panel.y;
    float3 sum = 0.0f;
    for (uint pixel = index; pixel < pixel_count; pixel += partial_count) {
        const uint2 position = uint2(pixel % p.source_panel.x, pixel / p.source_panel.x);
        const float3 code = device_signal.read(position).xyz;
        sum += float3(
            continuous_channel(code.r, p),
            continuous_channel(code.g, p),
            continuous_channel(code.b, p)
        );
    }
    partials[index] = float4(sum, 0.0f);
}

kernel void finalize_physical_veiling_source(
    device const float4* partials [[buffer(0)]],
    device float4* gate_average [[buffer(1)]],
    constant PhysicalPipelineParams& p [[buffer(2)]],
    uint index [[thread_position_in_grid]]
) {
    if (index != 0) return;
    constexpr uint partial_count = 256;
    float3 mean_native = 0.0f;
    for (uint partial = 0; partial < partial_count; ++partial) {
        mean_native += partials[partial].xyz;
    }
    mean_native /= float(p.source_panel.x * p.source_panel.y);
    const float facing = p.lens_veiling_glare.z;
    const float3 angular = float3(
        pow(clamp(facing, 0.0f, 1.0f), p.panel_angular_scene.x),
        pow(clamp(facing, 0.0f, 1.0f), p.panel_angular_scene.y),
        pow(clamp(facing, 0.0f, 1.0f), p.panel_angular_scene.z)
    );
    const PhysicalIdealPoint gate_center = physical_ideal_point(0.0f, p);
    const float3 irradiance = gate_center.valid
        ? float3(
            physical_irradiance_weight_from_ideal(gate_center.point, 0, p),
            physical_irradiance_weight_from_ideal(gate_center.point, 1, p),
            physical_irradiance_weight_from_ideal(gate_center.point, 2, p)
        )
        : float3(0.0f);
    const float3 weighted_native = mean_native * angular
        * irradiance
        * flat_cover_transmission(facing, p) * p.lens_veiling_glare.y;
    const float3 acescg = float3(
        dot(p.matrix0.xyz, weighted_native),
        dot(p.matrix1.xyz, weighted_native),
        dot(p.matrix2.xyz, weighted_native)
    ) / p.levels.z;
    gate_average[0] = float4(acescg, 0.0f);
}

kernel void evaluate_physical_pipeline(
    texture2d<float, access::read> source_acescg [[texture(0)]],
    texture2d<float, access::read> device_signal [[texture(1)]],
    texture2d<float, access::write> output [[texture(2)]],
    texture2d<float, access::read> source_row_prefix [[texture(3)]],
    texture2d<float, access::read> device_row_prefix [[texture(4)]],
    texture2d<float, access::sample> environment_acescg [[texture(5)]],
    constant PhysicalPipelineParams& p [[buffer(0)]],
    device const float* row_temporal_gains [[buffer(1)]],
    device const float4* veiling_gate_average [[buffer(2)]],
    uint2 local_position [[thread_position_in_grid]]
) {
    const uint2 position = uint2(local_position.x, local_position.y + p.output_tile.z);
    if (position.x >= p.output_tile.x || position.y >= p.output_tile.y) return;
    const uint side = p.output_tile.w;
    float4 ideal = 0.0f;
    float3 native = 0.0f;
    float3 uniform_native = 0.0f;
    float3 spread_native = 0.0f;
    float3 glow_native = 0.0f;
    float3 exterior_glow_native = 0.0f;
    float3 carrier_detail_native = 0.0f;
    float3 continuous_native = 0.0f;
    float3 uniform_continuous_native = 0.0f;
    float3 average_device_code = 0.0f;
    float cover_cosine = 0.0f;
    float3 cover_direction = 0.0f;
    float2 cover_uv = 0.0f;
    float2 cover_half_extent = 0.0f;
    float3 cover_irradiance = 0.0f;
    float cover_weight = 0.0f;
    float aperture_weight = 0.0f;
    const uint requested_stage = p.semantics.z;
    const bool final_optical = requested_stage >= 6;
    const bool needs_ideal_rgb = requested_stage == 0 || final_optical;
    const bool needs_average_code = requested_stage == 1;
    const bool needs_continuous = requested_stage == 2 || final_optical;
    const bool needs_moire_decomposition = final_optical
        && (p.geometry.w != 1.0f || p.geometry.y != 1.0f);
    const bool needs_physical = requested_stage == 3
        || (final_optical && p.uniformity_scales.w == 0.0f
            && (p.strengths.z != 1.0f || needs_moire_decomposition));
    const bool needs_uniform = requested_stage == 4
        || (final_optical && p.uniformity_scales.w != 0.0f
            && (p.strengths.z != 1.0f || needs_moire_decomposition));
    const bool needs_spread = requested_stage == 5;
    const bool needs_glow = final_optical;
    const bool needs_carrier = final_optical && VFX_DEPTH_BLUR
        && p.strengths.z != 0.0f;
    const float2 prepared_placement_scale = placement_scale(p);
    const uint psf_samples_per_area = p.lens_softness.z == 0.0f ? 1 : 16 / (side * side);
    const bool vfx_depth_blur = VFX_DEPTH_BLUR;
    const float sensor_pitch_mm = p.camera_right_sensor_width.w / float(p.output_tile.x);
    const float airy_radius_mm = 1.22f * 0.000550f * p.camera_limits.x;
    const float4 inverse_screen_quaternion = float4(
        -p.screen_quaternion.xyz, p.screen_quaternion.w);
    const PhysicalLensOrigin sensor_origin = physical_lens_origin(
        float2(0.0f), inverse_screen_quaternion, p);
    const PhysicalLensOrigin rim_x_origin = physical_lens_origin(
        float2(1.0f, 0.0f), inverse_screen_quaternion, p);
    const PhysicalLensOrigin rim_y_origin = physical_lens_origin(
        float2(0.0f, 1.0f), inverse_screen_quaternion, p);
    for (uint sy = 0; sy < side; ++sy) {
        for (uint sx = 0; sx < side; ++sx) {
            const float2 base_minimum_uv = (
                float2(position) + float2(sx, sy) / float(side)
            ) / float2(p.output_tile.xy);
            const float2 base_maximum_uv = (
                float2(position) + float2(sx + 1, sy + 1) / float(side)
            ) / float2(p.output_tile.xy);
            const float2 base_center = (base_minimum_uv + base_maximum_uv) * 0.5f;
            const float2 base_observed = base_center * 2.0f - 1.0f;
            const float field = clamp(dot(base_observed, base_observed) * 0.5f, 0.0f, 1.0f);
            const float softness_mm = mix(p.lens_softness.x, p.lens_softness.y, field) * 0.001f;
            const float psf_radius_mm = vfx_depth_blur
                ? length(float2(softness_mm, airy_radius_mm))
                : softness_mm + airy_radius_mm;
            const float psf_pixels = (psf_radius_mm / sensor_pitch_mm) * p.lens_softness.z;
            for (uint psf_sample = 0; psf_sample < psf_samples_per_area; ++psf_sample) {
            const uint sample_index = (sy * side + sx) * psf_samples_per_area + psf_sample;
            const float2 psf_offset = physical_psf_disk_sample(sample_index)
                * psf_pixels / float2(p.output_tile.xy);
            const float2 minimum_uv = base_minimum_uv + psf_offset;
            const float2 maximum_uv = base_maximum_uv + psf_offset;
            const float2 flat_center = base_center + psf_offset;
            const float2 observed = flat_center * 2.0f - 1.0f;
            const float2 half_extent = (maximum_uv - minimum_uv) * 0.5f;
            const PhysicalIdealPoint center_ideal = physical_ideal_point(observed, p);
            PhysicalIdealPoint sensor_positive_x_ideal = physical_invalid_ideal_point();
            PhysicalIdealPoint sensor_negative_x_ideal = physical_invalid_ideal_point();
            PhysicalIdealPoint sensor_positive_y_ideal = physical_invalid_ideal_point();
            PhysicalIdealPoint sensor_negative_y_ideal = physical_invalid_ideal_point();
            if (vfx_depth_blur) {
                const float2 sensor_ndc_half_extent = half_extent * 2.0f;
                sensor_positive_x_ideal = physical_ideal_point(
                    observed + float2(sensor_ndc_half_extent.x, 0.0f), p);
                sensor_negative_x_ideal = physical_ideal_point(
                    observed - float2(sensor_ndc_half_extent.x, 0.0f), p);
                sensor_positive_y_ideal = physical_ideal_point(
                    observed + float2(0.0f, sensor_ndc_half_extent.y), p);
                sensor_negative_y_ideal = physical_ideal_point(
                    observed - float2(0.0f, sensor_ndc_half_extent.y), p);
            }
            // Irradiance depends only on the resolved ideal sensor point and
            // channel, never on the sampled point across the physical pupil.
            const float3 sample_irradiance = center_ideal.valid
                ? float3(
                    physical_irradiance_weight_from_ideal(center_ideal.point, 0, p),
                    physical_irradiance_weight_from_ideal(center_ideal.point, 1, p),
                    physical_irradiance_weight_from_ideal(center_ideal.point, 2, p)
                )
                : float3(0.0f);
            const uint aperture_sample_count = vfx_depth_blur ? 1 : 32;
            for (uint aperture = 0; aperture < aperture_sample_count; ++aperture) {
            const float2 lens_sample = vfx_depth_blur
                ? float2(0.0f) : physical_aperture_sample(aperture);
            PhysicalLensOrigin lens_origin = sensor_origin;
            if (!vfx_depth_blur) {
                lens_origin = physical_lens_origin(
                    lens_sample, inverse_screen_quaternion, p);
            }
            const float layer_weight = 1.0f;
            aperture_weight += layer_weight;
            PhysicalRayFootprint green_footprint;
            green_footprint.hit = physical_ray_miss();
            green_footprint.projected_sensor_half_extent = half_extent;
            green_footprint.continuous_half_extent = 0.0f;
            for (uint channel = 0; channel < 3; ++channel) {
                const PhysicalRayFootprint footprint = physical_ray_footprint(
                    center_ideal,
                    sensor_positive_x_ideal,
                    sensor_negative_x_ideal,
                    sensor_positive_y_ideal,
                    sensor_negative_y_ideal,
                    lens_origin,
                    sensor_origin,
                    rim_x_origin,
                    rim_y_origin,
                    inverse_screen_quaternion,
                    channel,
                    half_extent,
                    vfx_depth_blur,
                    p
                );
                if (channel == 1) green_footprint = footprint;
                const PhysicalRayHit hit = footprint.hit;
                const float2 continuous_half_extent = footprint.continuous_half_extent;
                const float2 projected_sensor_half_extent =
                    footprint.projected_sensor_half_extent;
                const float2 target = hit.valid ? hit.uv : float2(-2.0f);
                const float2 center = mix(flat_center, target, p.panel_angular_scene.w);
                const bool exact_flat = p.panel_angular_scene.w == 0.0f
                    && p.lens_softness.z == 0.0f && p.lens_softness.w == 0.0f;
                const float2 sensor_half_extent = mix(
                    half_extent, projected_sensor_half_extent, p.panel_angular_scene.w);
                const float2 antialias_extra = half_extent * p.lens_softness.w;
                const float2 reconstructed_half_extent =
                    sensor_half_extent + continuous_half_extent + antialias_extra;
                const float2 carrier_half_extent =
                    sensor_half_extent * float2(0.25f, 1.0f)
                    + continuous_half_extent + antialias_extra;
                const float2 channel_minimum = exact_flat
                    ? minimum_uv : center - reconstructed_half_extent;
                const float2 channel_maximum = exact_flat
                    ? maximum_uv : center + reconstructed_half_extent;
                const float2 carrier_minimum = exact_flat
                    ? minimum_uv : center - carrier_half_extent;
                const float2 carrier_maximum = exact_flat
                    ? maximum_uv : center + carrier_half_extent;
                const float angular = hit.valid && hit.cosine != 0.0f
                    ? pow(clamp(hit.cosine, 0.0f, 1.0f), p.panel_angular_scene[channel])
                        * sample_irradiance[channel]
                    : 0.0f;
                const float optical_weight = mix(1.0f, angular, p.panel_angular_scene.w)
                    * layer_weight;
                float4 code = 0.0f;
                if (needs_average_code || needs_continuous || needs_physical || needs_uniform
                    || needs_spread || needs_glow || needs_carrier) {
                    code = area_sample(
                        device_signal, device_row_prefix,
                        channel_minimum, channel_maximum, prepared_placement_scale, p);
                }
                if (needs_average_code) average_device_code[channel] += code[channel];
                const float2 device_minimum = channel_minimum * float2(p.source_panel.zw);
                const float2 device_maximum = channel_maximum * float2(p.source_panel.zw);
                // Every Panel branch consumes the same central integral and EOTF.
                // Only displaced spread/glow taps and the narrow carrier remain distinct.
                const float base_linear = panel_linear_channel(code[channel], p);
                const float base_native = native_channel_from_linear(
                    base_linear, channel, device_minimum, device_maximum, p);
                const float base_gain = panel_uniformity_gains(
                    device_minimum, device_maximum, code.rgb, p)[channel];
                const float uniform_base_native = base_native * base_gain;
                if (needs_carrier) {
                    const float4 carrier_code = area_sample(
                        device_signal, device_row_prefix,
                        carrier_minimum, carrier_maximum, prepared_placement_scale, p);
                    const float preserved_carrier = native_channel(
                        carrier_code[channel], channel,
                        carrier_minimum * float2(p.source_panel.zw),
                        carrier_maximum * float2(p.source_panel.zw), p);
                    const float carrier_gain = panel_uniformity_gains(
                        carrier_minimum * float2(p.source_panel.zw),
                        carrier_maximum * float2(p.source_panel.zw), carrier_code.rgb, p)[channel];
                    carrier_detail_native[channel] +=
                        (preserved_carrier * carrier_gain - uniform_base_native) * optical_weight;
                }
                if (needs_physical) {
                    native[channel] += base_native * optical_weight;
                }
                if (needs_uniform) {
                    uniform_native[channel] += uniform_base_native * optical_weight;
                }
                if (needs_spread) {
                    spread_native[channel] += spread_native_channel(
                        device_signal, device_row_prefix, channel,
                        channel_minimum, channel_maximum, base_native,
                        prepared_placement_scale, p) * base_gain * optical_weight;
                }
                if (needs_glow) {
                    float exterior_scattered = 0.0f;
                    glow_native[channel] += cover_glow_native_channel(
                        device_signal, device_row_prefix, channel,
                        channel_minimum, channel_maximum, base_native,
                        prepared_placement_scale, exterior_scattered, p)
                        * base_gain * optical_weight;
                    exterior_glow_native[channel] += exterior_scattered
                        * base_gain * optical_weight;
                }
                if (needs_continuous) {
                    continuous_native[channel] += base_linear * optical_weight;
                    uniform_continuous_native[channel] += base_linear * base_gain * optical_weight;
                }
            }
            const PhysicalRayHit green_hit = green_footprint.hit;
            const float2 green_continuous_half_extent =
                green_footprint.continuous_half_extent;
            const float2 green_projected_sensor_half_extent =
                green_footprint.projected_sensor_half_extent;
            if (green_hit.valid) {
                cover_cosine += green_hit.cosine * layer_weight;
                cover_direction += green_hit.reflection_direction * layer_weight;
                cover_uv += green_hit.uv * layer_weight;
                cover_half_extent += (green_projected_sensor_half_extent
                    + green_continuous_half_extent
                    + half_extent * p.lens_softness.w) * layer_weight;
                cover_irradiance += sample_irradiance * layer_weight;
                cover_weight += layer_weight;
            }
            const float2 green_target = green_hit.valid ? green_hit.uv : float2(-2.0f);
            const float2 green_center = mix(flat_center, green_target, p.panel_angular_scene.w);
            const bool exact_flat = p.panel_angular_scene.w == 0.0f
                && p.lens_softness.z == 0.0f && p.lens_softness.w == 0.0f;
            const float2 green_sensor_half_extent = mix(
                half_extent, green_projected_sensor_half_extent, p.panel_angular_scene.w);
            const float2 green_reconstructed_half_extent =
                green_sensor_half_extent + green_continuous_half_extent
                + half_extent * p.lens_softness.w;
            const float4 ideal_sample = area_sample(source_acescg, source_row_prefix,
                exact_flat ? minimum_uv : green_center - green_reconstructed_half_extent,
                exact_flat ? maximum_uv : green_center + green_reconstructed_half_extent,
                prepared_placement_scale, p);
            ideal.a += ideal_sample.a * layer_weight;
            if (needs_ideal_rgb) ideal.rgb += ideal_sample.rgb * layer_weight;
            }
            }
        }
    }
    const float reciprocal = 1.0f / aperture_weight;
    const float cover_reciprocal = cover_weight == 0.0f ? 1.0f : 1.0f / cover_weight;
    const float3 cover_reflection_direction = length_squared(cover_direction) > 1.0e-12f
        ? normalize(cover_direction) : float3(0.0f, 0.0f, 1.0f);
    const float2 cover_position_meters = float2(
        (cover_uv.x * cover_reciprocal - 0.5f) * p.panel_size_meters.x,
        (0.5f - cover_uv.y * cover_reciprocal) * p.panel_size_meters.y);
    const float2 cover_footprint_half_extent_meters = cover_half_extent
        * cover_reciprocal * p.panel_size_meters.xy;
    ideal *= reciprocal;
    native *= reciprocal;
    uniform_native *= reciprocal;
    spread_native *= reciprocal;
    glow_native *= reciprocal;
    exterior_glow_native *= reciprocal;
    carrier_detail_native *= reciprocal;
    continuous_native *= reciprocal;
    uniform_continuous_native *= reciprocal;
    average_device_code *= reciprocal;
    const float3 physical = float3(
        dot(p.matrix0.xyz, native),
        dot(p.matrix1.xyz, native),
        dot(p.matrix2.xyz, native)
    ) / p.levels.z;
    const float3 uniform = float3(
        dot(p.matrix0.xyz, uniform_native),
        dot(p.matrix1.xyz, uniform_native),
        dot(p.matrix2.xyz, uniform_native)
    ) / p.levels.z;
    const float3 continuous = float3(
        dot(p.matrix0.xyz, continuous_native),
        dot(p.matrix1.xyz, continuous_native),
        dot(p.matrix2.xyz, continuous_native)
    ) / p.levels.z;
    const float3 uniform_continuous = float3(
        dot(p.matrix0.xyz, uniform_continuous_native),
        dot(p.matrix1.xyz, uniform_continuous_native),
        dot(p.matrix2.xyz, uniform_continuous_native)
    ) / p.levels.z;
    const float3 spread = float3(
        dot(p.matrix0.xyz, spread_native),
        dot(p.matrix1.xyz, spread_native),
        dot(p.matrix2.xyz, spread_native)
    ) / p.levels.z;
    const float3 glow = float3(
        dot(p.matrix0.xyz, glow_native),
        dot(p.matrix1.xyz, glow_native),
        dot(p.matrix2.xyz, glow_native)
    ) / p.levels.z;
    const float3 exterior_scattered_glow = float3(
        dot(p.matrix0.xyz, exterior_glow_native),
        dot(p.matrix1.xyz, exterior_glow_native),
        dot(p.matrix2.xyz, exterior_glow_native)
    ) / p.levels.z;
    float3 carrier_detail = float3(
        dot(p.matrix0.xyz, carrier_detail_native),
        dot(p.matrix1.xyz, carrier_detail_native),
        dot(p.matrix2.xyz, carrier_detail_native)
    ) / p.levels.z;
    const float moire_saturation = p.geometry.y;
    const float moire_intensity = p.geometry.w;
    float3 sampled_panel;
    if (p.uniformity_scales.w == 0.0f) {
        sampled_panel = ideal.rgb * (1.0f - p.strengths.y)
            + continuous * (p.strengths.y - p.strengths.z)
            + physical * (p.strengths.z - 1.0f)
            + glow
            + carrier_detail * p.strengths.z;
    } else {
        sampled_panel = ideal.rgb * (1.0f - p.strengths.y)
            + uniform_continuous * (p.strengths.y - p.strengths.z)
            + uniform * (p.strengths.z - 1.0f)
            + glow
            + carrier_detail * p.strengths.z;
    }
    const float3 sampled_structure_residual = p.uniformity_scales.w == 0.0f
        ? (physical - continuous) * p.strengths.z
        : (uniform - uniform_continuous) * p.strengths.z;
    const float3 structure_preserving_base = sampled_panel - sampled_structure_residual;
    float3 interference = sampled_panel - structure_preserving_base;
    if (moire_saturation != 1.0f) {
        const float residual_luminance = dot(
            interference,
            float3(0.27222872f, 0.67408174f, 0.053689517f)
        );
        interference = residual_luminance
            + moire_saturation * (interference - residual_luminance);
    }
    const float3 glass_scattered = structure_preserving_base + moire_intensity * interference;
    const float temporal_gain = 1.0f + p.strengths.w * (row_temporal_gains[position.y] - 1.0f);
    const float3 temporally_integrated = glass_scattered * temporal_gain;
    const float3 covered_with_environment = apply_flat_cover(temporally_integrated,
        cover_cosine * cover_reciprocal, cover_reflection_direction,
        cover_irradiance * cover_reciprocal, cover_position_meters,
        cover_footprint_half_extent_meters, environment_acescg, position, p);
    const float panel_coverage = panel_rectangle_coverage(
        cover_position_meters, cover_footprint_half_extent_meters, p);
    // The complete glow term conserves the unscattered panel base for samples
    // inside the active outline. Outside the panel only the separately
    // accumulated core/tail energy exists.
    const float3 exterior_glow = exterior_scattered_glow * temporal_gain
        * flat_cover_transmission(cover_cosine * cover_reciprocal, p);
    const float3 covered = mix(
        exterior_glow, covered_with_environment, panel_coverage);
    const float3 glared = mix(covered, veiling_gate_average[0].xyz * temporal_gain,
        p.lens_veiling_glare.x);
    const float shutter_scale = pow(p.shutter.y * exp2(-p.shutter.z), p.shutter.x);
    const float3 shuttered = glared * shutter_scale;
    float3 selected;
    switch (p.semantics.z) {
        case 0: selected = ideal.rgb; break;
        case 1: selected = average_device_code; break;
        case 2: selected = continuous; break;
        case 3: selected = physical; break;
        case 4: selected = uniform; break;
        case 5: selected = spread; break;
        case 6: selected = temporally_integrated; break;
        case 7: selected = covered; break;
        case 8: selected = covered; break;
        case 9: selected = glared; break;
        case 10: selected = shuttered; break;
        default: selected = ideal.rgb + p.strengths.x * (shuttered - ideal.rgb); break;
    }
    const float selected_alpha = p.semantics.z >= 7 ? panel_coverage : ideal.a;
    output.write(float4(selected, selected_alpha), position);
}

kernel void accumulate_physical_pipeline(
    texture2d<float, access::read> sample [[texture(0)]],
    texture2d<float, access::read_write> accumulated [[texture(1)]],
    constant float4 &weight_reset_row [[buffer(0)]],
    uint2 position [[thread_position_in_grid]])
{
    const uint2 target = uint2(position.x, position.y + uint(weight_reset_row.z));
    if (target.x >= sample.get_width() || target.y >= sample.get_height()
        || position.y >= uint(weight_reset_row.w)) {
        return;
    }
    const float4 weighted = sample.read(target) * weight_reset_row.x;
    accumulated.write(weight_reset_row.y != 0.0f ? weighted : accumulated.read(target) + weighted,
        target);
}
