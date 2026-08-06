#include <metal_stdlib>
using namespace metal;

struct DeviceStageUniforms {
    float4 matrixRow0;
    float4 matrixRow1;
    float4 matrixRow2;
    float4 levels;
};

kernel void evaluateDeviceStage(
    texture2d<half, access::read> acescg [[texture(0)]],
    texture2d<half, access::read> deviceCode [[texture(1)]],
    texture2d<half, access::write> result [[texture(2)]],
    constant DeviceStageUniforms &uniforms [[buffer(0)]],
    uint2 position [[thread_position_in_grid]]
) {
    if (position.x >= result.get_width() || position.y >= result.get_height()) {
        return;
    }
    const float4 source = float4(acescg.read(position));
    const float3 code = float3(deviceCode.read(position).rgb);
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
