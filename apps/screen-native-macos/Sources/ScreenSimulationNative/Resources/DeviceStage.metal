#include <metal_stdlib>
using namespace metal;

struct DeviceStageUniforms {
    float4 matrixRow0;
    float4 matrixRow1;
    float4 matrixRow2;
    float4 levels;
    float4 geometry;
};

kernel void evaluateDeviceStage(
    texture2d<half, access::sample> acescg [[texture(0)]],
    texture2d<half, access::sample> deviceCode [[texture(1)]],
    texture2d<half, access::write> result [[texture(2)]],
    sampler sourceSampler [[sampler(0)]],
    constant DeviceStageUniforms &uniforms [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= result.get_width() || position.y >= result.get_height()) {
        return;
    }
    const float2 deviceUV = (float2(position) + 0.5) / float2(result.get_width(), result.get_height());
    const float sourceAspect = uniforms.geometry.x;
    const float deviceAspect = uniforms.geometry.y;
    const uint placement = uint(round(uniforms.geometry.z));
    float2 scale = float2(1.0);
    if (placement == 0) {
        scale = sourceAspect > deviceAspect
            ? float2(1.0, sourceAspect / deviceAspect)
            : float2(deviceAspect / sourceAspect, 1.0);
    } else if (placement == 1) {
        scale = sourceAspect > deviceAspect
            ? float2(deviceAspect / sourceAspect, 1.0)
            : float2(1.0, sourceAspect / deviceAspect);
    } else if (placement == 3) {
        const float widthScale = uniforms.geometry.w;
        scale = float2(widthScale, widthScale * sourceAspect / deviceAspect);
    }
    const float2 sourceUV = (deviceUV - 0.5) * scale + 0.5;
    const float4 source = float4(acescg.sample(sourceSampler, sourceUV));
    const float3 code = float3(deviceCode.sample(sourceSampler, sourceUV).rgb);
    const float gamma = uniforms.levels.x;
    const float black = uniforms.levels.y;
    const float white = uniforms.levels.z;
    const float amount = uniforms.levels.w;
    const float3 powered = sign(code) * pow(abs(code), float3(gamma));
    const float3 nativeNits = black + (white - black) * powered;
    const float3 physicalACEScg = float3(
        dot(uniforms.matrixRow0.xyz, nativeNits),
        dot(uniforms.matrixRow1.xyz, nativeNits),
        dot(uniforms.matrixRow2.xyz, nativeNits)
    ) / white;
    result.write(half4(half3(mix(source.rgb, physicalACEScg, amount)), half(source.a)), position);
}
