import Foundation
import Metal
import simd
import StudioColor

enum SetupFramingError: Error, LocalizedError {
    case unavailableMetal
    case invalidContract
    case commandFailed

    var errorDescription: String? {
        switch self {
        case .unavailableMetal: "Setup no puede crear su evaluador Metal."
        case .invalidContract: "Los parámetros de encuadre Setup no son válidos."
        case .commandFailed: "El encuadre Setup no ha podido completarse."
        }
    }
}

@MainActor
final class SetupFramingRenderer {
    private struct Parameters {
        var cameraPositionFocal: SIMD4<Float>
        var cameraRightSensorWidth: SIMD4<Float>
        var cameraUpSensorHeight: SIMD4<Float>
        var cameraForward: SIMD4<Float>
        var screenPositionWidth: SIMD4<Float>
        var screenQuaternion: SIMD4<Float>
        var screenHeightShiftY: SIMD4<Float>
        var raster: SIMD4<UInt32>
        var sourceDevice: SIMD4<UInt32>
        var modes: SIMD4<UInt32>
    }

    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let sampler: MTLSamplerState

    init(device: MTLDevice) throws {
        guard let queue = device.makeCommandQueue() else {
            throw SetupFramingError.unavailableMetal
        }
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        guard let function = library.makeFunction(name: "setup_framing") else {
            throw SetupFramingError.unavailableMetal
        }
        pipeline = try device.makeComputePipelineState(function: function)
        let descriptor = MTLSamplerDescriptor()
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: descriptor) else {
            throw SetupFramingError.unavailableMetal
        }
        self.queue = queue
        self.sampler = sampler
    }

    func render(
        source: StudioColorMetalFrame,
        sourcePlacement: WorkspaceModel.SourcePlacement,
        device: DeviceDefinition,
        pipeline authored: PhysicalPipelineAuthoringState,
        deliveryWidth: Int,
        deliveryHeight: Int,
        deliveryPlacementID: String,
        deliveryBackgroundID: String
    ) throws -> StudioColorMetalFrame {
        guard deliveryWidth > 0, deliveryHeight > 0,
              authored.cameraPose.position.count == 3,
              authored.cameraPose.quaternion.count == 4,
              authored.screenPose.position.count == 3,
              authored.screenPose.quaternion.count == 4,
              authored.sceneLens.sensorWidthMillimeters > 0,
              authored.sceneLens.sensorHeightMillimeters > 0,
              authored.sceneLens.focalLengthMillimeters > 0
        else { throw SetupFramingError.invalidContract }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: deliveryWidth,
            height: deliveryHeight,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let output = source.texture.device.makeTexture(descriptor: descriptor),
              let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder()
        else { throw SetupFramingError.unavailableMetal }

        let cameraQ = authored.cameraPose.quaternion.map(Float.init)
        let right = Self.rotate([1, 0, 0], by: cameraQ)
        let up = Self.rotate([0, 1, 0], by: cameraQ)
        let forward = Self.rotate([0, 0, -1], by: cameraQ)
        let cameraRaster = authored.sensor
        let deliveryPlacement: UInt32 = switch deliveryPlacementID {
        case "fit": 0
        case "one-to-one": 1
        case "fill-crop": 2
        default: throw SetupFramingError.invalidContract
        }
        var parameters = Parameters(
            cameraPositionFocal: SIMD4(
                Float(authored.cameraPose.position[0]), Float(authored.cameraPose.position[1]),
                Float(authored.cameraPose.position[2]), Float(authored.sceneLens.focalLengthMillimeters)
            ),
            cameraRightSensorWidth: SIMD4(
                right.x, right.y, right.z, Float(authored.sceneLens.sensorWidthMillimeters)
            ),
            cameraUpSensorHeight: SIMD4(
                up.x, up.y, up.z, Float(authored.sceneLens.sensorHeightMillimeters)
            ),
            cameraForward: SIMD4(forward.x, forward.y, forward.z, 0),
            screenPositionWidth: SIMD4(
                Float(authored.screenPose.position[0]), Float(authored.screenPose.position[1]),
                Float(authored.screenPose.position[2]), Float(device.activeWidthMeters)
            ),
            screenQuaternion: SIMD4(
                Float(authored.screenPose.quaternion[0]), Float(authored.screenPose.quaternion[1]),
                Float(authored.screenPose.quaternion[2]), Float(authored.screenPose.quaternion[3])
            ),
            screenHeightShiftY: SIMD4(
                Float(device.activeHeightMeters), Float(authored.sceneLens.lensShift[1]), 0, 0
            ),
            raster: SIMD4(
                UInt32(deliveryWidth), UInt32(deliveryHeight),
                cameraRaster.nativeWidth, cameraRaster.nativeHeight
            ),
            sourceDevice: SIMD4(
                UInt32(source.width), UInt32(source.height),
                UInt32(device.nativeWidth), UInt32(device.nativeHeight)
            ),
            modes: SIMD4(
                Self.sourcePlacement(sourcePlacement),
                deliveryPlacement,
                deliveryBackgroundID == "transparent" ? 0 : 1,
                0
            )
        )
        parameters.cameraForward.w = Float(authored.sceneLens.lensShift[0])

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source.texture, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setSamplerState(sampler, index: 0)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 0)
        let width = pipeline.threadExecutionWidth
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        encoder.dispatchThreads(
            MTLSize(width: deliveryWidth, height: deliveryHeight, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1)
        )
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw SetupFramingError.commandFailed }
        return StudioColorMetalFrame(texture: output)
    }

    private static func sourcePlacement(_ placement: WorkspaceModel.SourcePlacement) -> UInt32 {
        switch placement {
        case .fit: 0
        case .fillCrop: 1
        case .stretch: 2
        case .oneToOne: 3
        }
    }

    private static func rotate(_ vector: SIMD3<Float>, by q: [Float]) -> SIMD3<Float> {
        let xyz = SIMD3(q[0], q[1], q[2])
        let t = 2 * simd_cross(xyz, vector)
        return vector + q[3] * t + simd_cross(xyz, t)
    }

    private static let shader = #"""
    #include <metal_stdlib>
    using namespace metal;

    struct SetupParameters {
        float4 camera_position_focal;
        float4 camera_right_sensor_width;
        float4 camera_up_sensor_height;
        float4 camera_forward_shift_x;
        float4 screen_position_width;
        float4 screen_quaternion;
        float4 screen_height_shift_y;
        uint4 raster;
        uint4 source_device;
        uint4 modes;
    };

    inline float3 rotate_q(float4 q, float3 v) {
        const float3 t = 2.0f * cross(q.xyz, v);
        return v + q.w * t + cross(q.xyz, t);
    }

    inline bool camera_uv(uint2 p, constant SetupParameters& s, thread float2& uv) {
        const float2 output_size = float2(s.raster.xy);
        const float2 camera_size = float2(s.raster.zw);
        float2 camera_pixel;
        if (s.modes.y == 0 || s.modes.y == 2) {
            const float scale = s.modes.y == 0
                ? min(output_size.x / camera_size.x, output_size.y / camera_size.y)
                : max(output_size.x / camera_size.x, output_size.y / camera_size.y);
            const float2 offset = (output_size - camera_size * scale) * 0.5f;
            camera_pixel = (float2(p) + 0.5f - offset) / scale - 0.5f;
        } else {
            const int2 offset = (int2(s.raster.xy) - int2(s.raster.zw)) / 2;
            camera_pixel = float2(int2(p) - offset);
        }
        if (any(camera_pixel < -0.5f) || any(camera_pixel >= camera_size - 0.5f)) return false;
        uv = (camera_pixel + 0.5f) / camera_size;
        return true;
    }

    inline bool screen_uv(float2 camera_uv, constant SetupParameters& s, thread float2& uv) {
        const float2 observed = camera_uv * 2.0f - 1.0f;
        const float shift_y = s.screen_height_shift_y.y;
        const float2 ideal = float2(
            observed.x + 2.0f * s.camera_forward_shift_x.w,
            -observed.y - 2.0f * shift_y
        );
        const float focal = s.camera_position_focal.w;
        const float3 ray = normalize(
            s.camera_forward_shift_x.xyz
            + s.camera_right_sensor_width.xyz
                * (ideal.x * s.camera_right_sensor_width.w / (2.0f * focal))
            + s.camera_up_sensor_height.xyz
                * (ideal.y * s.camera_up_sensor_height.w / (2.0f * focal))
        );
        const float3 screen_right = rotate_q(s.screen_quaternion, float3(1, 0, 0));
        const float3 screen_up = rotate_q(s.screen_quaternion, float3(0, 1, 0));
        const float3 screen_normal = rotate_q(s.screen_quaternion, float3(0, 0, 1));
        const float denominator = dot(ray, screen_normal);
        if (abs(denominator) < 1.0e-8f) return false;
        const float distance = dot(
            s.screen_position_width.xyz - s.camera_position_focal.xyz,
            screen_normal
        ) / denominator;
        if (distance <= 0.0f) return false;
        const float3 local = s.camera_position_focal.xyz + ray * distance
            - s.screen_position_width.xyz;
        uv = float2(
            dot(local, screen_right) / s.screen_position_width.w + 0.5f,
            0.5f - dot(local, screen_up) / s.screen_height_shift_y.x
        );
        return true;
    }

    inline float2 source_uv(float2 device_uv, constant SetupParameters& s) {
        const float source_aspect = float(s.source_device.x) / float(s.source_device.y);
        const float device_aspect = float(s.source_device.z) / float(s.source_device.w);
        if (s.modes.x == 2) return device_uv;
        float2 scale = 1.0f;
        if (s.modes.x == 0) {
            scale = source_aspect > device_aspect
                ? float2(1.0f, source_aspect / device_aspect)
                : float2(device_aspect / source_aspect, 1.0f);
        } else if (s.modes.x == 1) {
            scale = source_aspect > device_aspect
                ? float2(device_aspect / source_aspect, 1.0f)
                : float2(1.0f, source_aspect / device_aspect);
        } else {
            scale = float2(s.source_device.zw) / float2(s.source_device.xy);
        }
        return (device_uv - 0.5f) * scale + 0.5f;
    }

    kernel void setup_framing(
        texture2d<float, access::sample> source [[texture(0)]],
        texture2d<float, access::write> output [[texture(1)]],
        sampler linear_sampler [[sampler(0)]],
        constant SetupParameters& s [[buffer(0)]],
        uint2 p [[thread_position_in_grid]]
    ) {
        if (any(p >= s.raster.xy)) return;
        const float4 background = s.modes.z == 0 ? float4(0) : float4(0, 0, 0, 1);
        float2 camera;
        if (!camera_uv(p, s, camera)) { output.write(background, p); return; }
        float2 panel;
        if (!screen_uv(camera, s, panel)) { output.write(background, p); return; }
        const bool inside = all(panel >= 0.0f) && all(panel <= 1.0f);
        if (!inside) { output.write(background, p); return; }

        float2 camera_x, camera_y, panel_x, panel_y;
        const bool x_ok = camera_uv(p + uint2(1, 0), s, camera_x) && screen_uv(camera_x, s, panel_x);
        const bool y_ok = camera_uv(p + uint2(0, 1), s, camera_y) && screen_uv(camera_y, s, panel_y);
        const float2 footprint = max(
            x_ok ? abs(panel_x - panel) : 0.0f,
            y_ok ? abs(panel_y - panel) : 0.0f
        );
        const float edge_distance = min(min(panel.x, 1.0f - panel.x), min(panel.y, 1.0f - panel.y));
        const float one_pixel = max(footprint.x, footprint.y) * 0.7f;
        if (edge_distance <= one_pixel) {
            output.write(float4(1, 0, 0, 1), p);
            return;
        }
        const float2 uv = source_uv(panel, s);
        if (any(uv < 0.0f) || any(uv > 1.0f)) {
            output.write(float4(0, 0, 0, 1), p);
            return;
        }
        float4 value = source.sample(linear_sampler, uv);
        value.a = 1.0f;
        output.write(value, p);
    }
    """#
}
