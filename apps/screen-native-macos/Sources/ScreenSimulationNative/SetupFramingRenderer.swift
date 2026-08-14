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
    struct Result {
        let frame: StudioColorMetalFrame
        /// Complete projected perimeter used by the red diagnostic stroke.
        let boundary: [CGPoint]
        /// Four rigid Device corners, clockwise from top-left.
        let corners: [CGPoint]
    }
    private struct Parameters {
        var cameraPositionFocal: SIMD4<Float>
        var cameraRightSensorWidth: SIMD4<Float>
        var cameraUpSensorHeight: SIMD4<Float>
        var cameraForward: SIMD4<Float>
        var screenPositionWidth: SIMD4<Float>
        var screenQuaternion: SIMD4<Float>
        var screenHeightShiftY: SIMD4<Float>
        var raster: SIMD4<UInt32>
        var previewRaster: SIMD4<UInt32>
        var sourceDevice: SIMD4<UInt32>
        var referenceRaster: SIMD4<UInt32>
        var modes: SIMD4<UInt32>
        var environment: SIMD4<Float>
        var lensRadialTangential: SIMD4<Float>
        var lensTangentialFocus: SIMD4<Float>
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
        reference: StudioColorMetalFrame? = nil,
        sourcePlacement: WorkspaceModel.SourcePlacement,
        referencePlacement: WorkspaceModel.SourcePlacement,
        device: DeviceDefinition,
        pipeline authored: PhysicalPipelineAuthoringState,
        deliveryWidth: Int,
        deliveryHeight: Int,
        deliveryPlacementID: String,
        deliveryBackgroundID: String,
        previewWidth: Int? = nil,
        previewHeight: Int? = nil,
        diagnosticMode: UInt32 = 0
    ) throws -> Result {
        let outputWidth = previewWidth ?? deliveryWidth
        let outputHeight = previewHeight ?? deliveryHeight
        guard deliveryWidth > 0, deliveryHeight > 0,
              outputWidth > 0, outputHeight > 0,
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
            width: outputWidth,
            height: outputHeight,
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
            previewRaster: SIMD4(UInt32(outputWidth), UInt32(outputHeight), 0, 0),
            sourceDevice: SIMD4(
                UInt32(source.width), UInt32(source.height),
                UInt32(device.nativeWidth), UInt32(device.nativeHeight)
            ),
            referenceRaster: SIMD4(
                UInt32(reference?.width ?? source.width),
                UInt32(reference?.height ?? source.height),
                Self.sourcePlacement(referencePlacement), 0
            ),
            modes: SIMD4(
                Self.sourcePlacement(sourcePlacement),
                deliveryPlacement,
                deliveryBackgroundID == "transparent" ? 0 : 1,
                diagnosticMode
            ),
            environment: SIMD4(
                Float(authored.environment.rotationXDegrees * .pi / 180),
                Float(authored.environment.rotationYDegrees * .pi / 180),
                Float(authored.environment.projectionMode),
                Float(authored.environment.sphereRadiusMeters)
            ),
            lensRadialTangential: SIMD4(
                Float(authored.sceneLens.radialDistortion[0]),
                Float(authored.sceneLens.radialDistortion[1]),
                Float(authored.sceneLens.radialDistortion[2]),
                Float(authored.sceneLens.tangentialDistortion[0])
            ),
            lensTangentialFocus: SIMD4(
                Float(authored.sceneLens.tangentialDistortion[1]),
                Float(authored.sceneLens.focusDistanceMeters),
                Float(authored.sceneLens.fStop), 0
            )
        )
        parameters.cameraForward.w = Float(authored.sceneLens.lensShift[0])

        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source.texture, index: 0)
        encoder.setTexture(output, index: 1)
        encoder.setTexture(reference?.texture ?? source.texture, index: 2)
        encoder.setSamplerState(sampler, index: 0)
        encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 0)
        let width = pipeline.threadExecutionWidth
        let height = max(1, pipeline.maxTotalThreadsPerThreadgroup / width)
        encoder.dispatchThreads(
            MTLSize(width: outputWidth, height: outputHeight, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1)
        )
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw SetupFramingError.commandFailed }
        let frame = StudioColorMetalFrame(texture: output)
        let boundary = Self.projectedBoundary(
            authored: authored, device: device,
            deliveryWidth: deliveryWidth, deliveryHeight: deliveryHeight,
            deliveryPlacement: deliveryPlacement,
            outputWidth: outputWidth, outputHeight: outputHeight,
            applyLensDistortion: diagnosticMode == 2 || diagnosticMode == 3 || diagnosticMode == 4,
            sampleDistortedEdges: diagnosticMode == 2 || diagnosticMode == 3 || diagnosticMode == 4
        )
        let corners = Self.projectedBoundary(
            authored: authored, device: device,
            deliveryWidth: deliveryWidth, deliveryHeight: deliveryHeight,
            deliveryPlacement: deliveryPlacement,
            outputWidth: outputWidth, outputHeight: outputHeight,
            applyLensDistortion: diagnosticMode == 2 || diagnosticMode == 3 || diagnosticMode == 4,
            sampleDistortedEdges: false
        )
        return Result(frame: frame, boundary: boundary, corners: corners)
    }

    func renderReferenceMatch(
        source: StudioColorMetalFrame,
        reference: StudioColorMetalFrame,
        sourcePlacement: WorkspaceModel.SourcePlacement,
        referencePlacement: WorkspaceModel.SourcePlacement,
        device: DeviceDefinition,
        pipeline authored: PhysicalPipelineAuthoringState,
        deliveryWidth: Int,
        deliveryHeight: Int,
        deliveryPlacementID: String,
        previewWidth: Int? = nil,
        previewHeight: Int? = nil
    ) throws -> Result {
        try render(
            source: source,
            reference: reference,
            sourcePlacement: sourcePlacement,
            referencePlacement: referencePlacement,
            device: device,
            pipeline: authored,
            deliveryWidth: deliveryWidth,
            deliveryHeight: deliveryHeight,
            deliveryPlacementID: deliveryPlacementID,
            deliveryBackgroundID: "black",
            previewWidth: previewWidth,
            previewHeight: previewHeight,
            diagnosticMode: 3
        )
    }

    func renderReferenceComposite(
        cameraResult: StudioColorMetalFrame,
        reference: StudioColorMetalFrame,
        referencePlacement: WorkspaceModel.SourcePlacement,
        device: DeviceDefinition,
        pipeline authored: PhysicalPipelineAuthoringState,
        deliveryWidth: Int,
        deliveryHeight: Int,
        deliveryPlacementID: String,
        deliveryAligned: Bool = false
    ) throws -> Result {
        try render(
            source: cameraResult,
            reference: reference,
            sourcePlacement: .stretch,
            referencePlacement: referencePlacement,
            device: device,
            pipeline: authored,
            deliveryWidth: deliveryWidth,
            deliveryHeight: deliveryHeight,
            deliveryPlacementID: deliveryPlacementID,
            deliveryBackgroundID: "black",
            diagnosticMode: deliveryAligned ? 5 : 4
        )
    }

    func renderEnvironment(
        environment: StudioColorMetalFrame,
        device: DeviceDefinition,
        pipeline authored: PhysicalPipelineAuthoringState,
        deliveryWidth: Int,
        deliveryHeight: Int,
        deliveryPlacementID: String,
        deliveryBackgroundID: String,
        previewWidth: Int? = nil,
        previewHeight: Int? = nil
    ) throws -> Result {
        try render(
            source: environment,
            sourcePlacement: .stretch,
            referencePlacement: .stretch,
            device: device,
            pipeline: authored,
            deliveryWidth: deliveryWidth,
            deliveryHeight: deliveryHeight,
            deliveryPlacementID: deliveryPlacementID,
            deliveryBackgroundID: deliveryBackgroundID,
            previewWidth: previewWidth,
            previewHeight: previewHeight,
            diagnosticMode: 1
        )
    }

    func renderFocus(
        source: StudioColorMetalFrame,
        device: DeviceDefinition,
        pipeline authored: PhysicalPipelineAuthoringState,
        deliveryWidth: Int,
        deliveryHeight: Int,
        deliveryPlacementID: String,
        deliveryBackgroundID: String,
        previewWidth: Int? = nil,
        previewHeight: Int? = nil
    ) throws -> Result {
        try render(
            source: source, sourcePlacement: .stretch,
            referencePlacement: .stretch,
            device: device, pipeline: authored,
            deliveryWidth: deliveryWidth, deliveryHeight: deliveryHeight,
            deliveryPlacementID: deliveryPlacementID,
            deliveryBackgroundID: deliveryBackgroundID,
            previewWidth: previewWidth, previewHeight: previewHeight,
            diagnosticMode: 2
        )
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

    private static func projectedBoundary(
        authored: PhysicalPipelineAuthoringState,
        device: DeviceDefinition,
        deliveryWidth: Int,
        deliveryHeight: Int,
        deliveryPlacement: UInt32,
        outputWidth: Int,
        outputHeight: Int,
        applyLensDistortion: Bool,
        sampleDistortedEdges: Bool
    ) -> [CGPoint] {
        let cameraQ = authored.cameraPose.quaternion.map(Float.init)
        let screenQ = authored.screenPose.quaternion.map(Float.init)
        let camera = SIMD3<Float>(
            Float(authored.cameraPose.position[0]), Float(authored.cameraPose.position[1]),
            Float(authored.cameraPose.position[2])
        )
        let screen = SIMD3<Float>(
            Float(authored.screenPose.position[0]), Float(authored.screenPose.position[1]),
            Float(authored.screenPose.position[2])
        )
        let cameraRight = rotate([1, 0, 0], by: cameraQ)
        let cameraUp = rotate([0, 1, 0], by: cameraQ)
        let cameraForward = rotate([0, 0, -1], by: cameraQ)
        let screenRight = rotate([1, 0, 0], by: screenQ)
        let screenUp = rotate([0, 1, 0], by: screenQ)
        let cameraSize = SIMD2<Float>(Float(authored.sensor.nativeWidth), Float(authored.sensor.nativeHeight))
        let outputSize = SIMD2<Float>(Float(deliveryWidth), Float(deliveryHeight))
        let scale: Float = switch deliveryPlacement {
        case 0: min(outputSize.x / cameraSize.x, outputSize.y / cameraSize.y)
        case 2: max(outputSize.x / cameraSize.x, outputSize.y / cameraSize.y)
        default: 1
        }
        let offset = (outputSize - cameraSize * scale) * 0.5
        let focal = Float(authored.sceneLens.focalLengthMillimeters)
        let sensorWidth = Float(authored.sceneLens.sensorWidthMillimeters)
        let sensorHeight = Float(authored.sceneLens.sensorHeightMillimeters)
        let shiftX = Float(authored.sceneLens.lensShift[0])
        let shiftY = Float(authored.sceneLens.lensShift[1])
        let halfWidth = Float(device.activeWidthMeters) * 0.5
        let halfHeight = Float(device.activeHeightMeters) * 0.5
        let edgeSamples = sampleDistortedEdges ? 64 : 1
        let corners: [(Float, Float)] = [(-1, 1), (1, 1), (1, -1), (-1, -1)]
        let perimeter = corners.indices.flatMap { edge -> [(Float, Float)] in
            let start = corners[edge]
            let end = corners[(edge + 1) % corners.count]
            return (0..<edgeSamples).map { sample in
                let t = Float(sample) / Float(edgeSamples)
                return (
                    start.0 + (end.0 - start.0) * t,
                    start.1 + (end.1 - start.1) * t
                )
            }
        }
        return perimeter.map { sx, sy in
            let world = screen + screenRight * (sx * halfWidth) + screenUp * (sy * halfHeight)
            let relative = world - camera
            let depth = simd_dot(relative, cameraForward)
            let idealX = simd_dot(relative, cameraRight) / depth * (2 * focal / sensorWidth)
            let idealY = simd_dot(relative, cameraUp) / depth * (2 * focal / sensorHeight)
            let distorted = applyLensDistortion
                ? Self.distort(
                    SIMD2(idealX, idealY),
                    radial: authored.sceneLens.radialDistortion,
                    tangential: authored.sceneLens.tangentialDistortion
                )
                : SIMD2(idealX, idealY)
            let observed = SIMD2<Float>(distorted.x - 2 * shiftX, -distorted.y - 2 * shiftY)
            let cameraPixel = (observed + 1) * 0.5 * cameraSize - 0.5
            let outputPixel = deliveryPlacement == 1
                ? cameraPixel + offset
                : (cameraPixel + 0.5) * scale - 0.5 + offset
            let preview = (outputPixel + 0.5) * SIMD2<Float>(
                Float(outputWidth) / Float(deliveryWidth),
                Float(outputHeight) / Float(deliveryHeight)
            ) - 0.5
            return CGPoint(x: CGFloat(preview.x), y: CGFloat(preview.y))
        }
    }

    private static func distort(
        _ point: SIMD2<Float>, radial: [Double], tangential: [Double]
    ) -> SIMD2<Float> {
        let r2 = simd_dot(point, point)
        let radialScale = 1 + Float(radial[0]) * r2
            + Float(radial[1]) * r2 * r2 + Float(radial[2]) * r2 * r2 * r2
        let p1 = Float(tangential[0])
        let p2 = Float(tangential[1])
        return point * radialScale + SIMD2(
            2 * p1 * point.x * point.y + p2 * (r2 + 2 * point.x * point.x),
            p1 * (r2 + 2 * point.y * point.y) + 2 * p2 * point.x * point.y
        )
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
        uint4 preview_raster;
        uint4 source_device;
        uint4 reference_raster;
        uint4 modes;
        float4 environment;
        float4 lens_radial_tangential;
        float4 lens_tangential_focus;
    };

    inline float3 rotate_q(float4 q, float3 v) {
        const float3 t = 2.0f * cross(q.xyz, v);
        return v + q.w * t + cross(q.xyz, t);
    }

    inline bool camera_uv_at(
        float2 preview_sample, constant SetupParameters& s, thread float2& uv
    ) {
        const float2 output_size = float2(s.raster.xy);
        const float2 camera_size = float2(s.raster.zw);
        const float2 output_pixel = preview_sample
            * output_size / float2(s.preview_raster.xy) - 0.5f;
        float2 camera_pixel;
        if (s.modes.y == 0 || s.modes.y == 2) {
            const float scale = s.modes.y == 0
                ? min(output_size.x / camera_size.x, output_size.y / camera_size.y)
                : max(output_size.x / camera_size.x, output_size.y / camera_size.y);
            const float2 offset = (output_size - camera_size * scale) * 0.5f;
            camera_pixel = (output_pixel + 0.5f - offset) / scale - 0.5f;
        } else {
            const int2 offset = (int2(s.raster.xy) - int2(s.raster.zw)) / 2;
            camera_pixel = output_pixel - float2(offset);
        }
        if (any(camera_pixel < -0.5f) || any(camera_pixel >= camera_size - 0.5f)) return false;
        uv = (camera_pixel + 0.5f) / camera_size;
        return true;
    }

    inline bool camera_uv(uint2 p, constant SetupParameters& s, thread float2& uv) {
        return camera_uv_at(float2(p) + 0.5f, s, uv);
    }

    inline bool delivery_uv(float2 camera_uv, constant SetupParameters& s, thread float2& uv) {
        const float2 output_size = float2(s.source_device.xy);
        const float2 camera_size = float2(s.raster.zw);
        const float2 camera_pixel = camera_uv * camera_size - 0.5f;
        float2 output_pixel;
        if (s.modes.y == 0 || s.modes.y == 2) {
            const float scale = s.modes.y == 0
                ? min(output_size.x / camera_size.x, output_size.y / camera_size.y)
                : max(output_size.x / camera_size.x, output_size.y / camera_size.y);
            const float2 offset = (output_size - camera_size * scale) * 0.5f;
            output_pixel = (camera_pixel + 0.5f) * scale - 0.5f + offset;
        } else {
            const int2 offset = (int2(s.source_device.xy) - int2(s.raster.zw)) / 2;
            output_pixel = camera_pixel + float2(offset);
        }
        if (any(output_pixel < -0.5f) || any(output_pixel >= output_size - 0.5f)) return false;
        uv = (output_pixel + 0.5f) / output_size;
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

    inline float2 distort_point(float2 point, constant SetupParameters& s) {
        const float r2 = dot(point, point);
        const float scale = 1.0f + s.lens_radial_tangential.x * r2
            + s.lens_radial_tangential.y * r2 * r2
            + s.lens_radial_tangential.z * r2 * r2 * r2;
        const float p1 = s.lens_radial_tangential.w;
        const float p2 = s.lens_tangential_focus.x;
        return point * scale + float2(
            2.0f * p1 * point.x * point.y + p2 * (r2 + 2.0f * point.x * point.x),
            p1 * (r2 + 2.0f * point.y * point.y) + 2.0f * p2 * point.x * point.y);
    }

    inline bool inverse_distortion(float2 observed, constant SetupParameters& s,
        thread float2& ideal) {
        ideal = observed;
        for (uint iteration = 0; iteration < 12; ++iteration) {
            const float2 projected = distort_point(ideal, s);
            const float2 residual = projected - observed;
            if (max(abs(residual.x), abs(residual.y)) < 1.0e-7f) break;
            const float e = 1.0e-4f;
            const float2 dx = (distort_point(ideal + float2(e, 0), s)
                - distort_point(ideal - float2(e, 0), s)) / (2.0f * e);
            const float2 dy = (distort_point(ideal + float2(0, e), s)
                - distort_point(ideal - float2(0, e), s)) / (2.0f * e);
            const float determinant = dx.x * dy.y - dy.x * dx.y;
            if (abs(determinant) < 1.0e-10f) return false;
            ideal -= float2(
                (dy.y * residual.x - dy.x * residual.y) / determinant,
                (-dx.y * residual.x + dx.x * residual.y) / determinant);
        }
        const float2 final_residual = abs(distort_point(ideal, s) - observed);
        return all(isfinite(ideal))
            && max(final_residual.x, final_residual.y) < 2.0e-4f;
    }

    inline bool focus_screen_sample(float2 camera_uv, constant SetupParameters& s,
        thread float2& panel_uv, thread float& optical_depth) {
        const float2 observed = camera_uv * 2.0f - 1.0f;
        float2 ideal;
        if (!inverse_distortion(float2(
            observed.x + 2.0f * s.camera_forward_shift_x.w,
            -observed.y - 2.0f * s.screen_height_shift_y.y), s, ideal)) return false;
        const float3 ray = normalize(s.camera_forward_shift_x.xyz
            + s.camera_right_sensor_width.xyz
                * (ideal.x * s.camera_right_sensor_width.w / (2.0f * s.camera_position_focal.w))
            + s.camera_up_sensor_height.xyz
                * (ideal.y * s.camera_up_sensor_height.w / (2.0f * s.camera_position_focal.w)));
        const float3 screen_right = rotate_q(s.screen_quaternion, float3(1, 0, 0));
        const float3 screen_up = rotate_q(s.screen_quaternion, float3(0, 1, 0));
        const float3 screen_normal = rotate_q(s.screen_quaternion, float3(0, 0, 1));
        const float denominator = dot(ray, screen_normal);
        if (abs(denominator) < 1.0e-8f) return false;
        const float distance = dot(s.screen_position_width.xyz - s.camera_position_focal.xyz,
            screen_normal) / denominator;
        if (distance <= 0.0f) return false;
        const float3 point = s.camera_position_focal.xyz + ray * distance;
        const float3 local = point - s.screen_position_width.xyz;
        panel_uv = float2(dot(local, screen_right) / s.screen_position_width.w + 0.5f,
            0.5f - dot(local, screen_up) / s.screen_height_shift_y.x);
        optical_depth = dot(point - s.camera_position_focal.xyz,
            s.camera_forward_shift_x.xyz);
        return true;
    }

    inline float3 camera_ray(float2 camera_uv, constant SetupParameters& s) {
        const float2 observed = camera_uv * 2.0f - 1.0f;
        const float2 ideal = float2(
            observed.x + 2.0f * s.camera_forward_shift_x.w,
            -observed.y - 2.0f * s.screen_height_shift_y.y);
        return normalize(s.camera_forward_shift_x.xyz
            + s.camera_right_sensor_width.xyz
                * (ideal.x * s.camera_right_sensor_width.w / (2.0f * s.camera_position_focal.w))
            + s.camera_up_sensor_height.xyz
                * (ideal.y * s.camera_up_sensor_height.w / (2.0f * s.camera_position_focal.w)));
    }

    inline float3 rotate_environment(float3 d, float rx, float ry) {
        const float sy = sin(ry), cy = cos(ry);
        d = float3(d.x * cy + d.z * sy, d.y, -d.x * sy + d.z * cy);
        const float sx = sin(rx), cx = cos(rx);
        return float3(d.x, d.y * cx - d.z * sx, d.y * sx + d.z * cx);
    }

    inline bool environment_uv(float2 camera_uv, constant SetupParameters& s, thread float2& uv) {
        const float3 ray = camera_ray(camera_uv, s);
        const float3 screen_normal = rotate_q(s.screen_quaternion, float3(0, 0, 1));
        const float denominator = dot(ray, screen_normal);
        if (abs(denominator) < 1.0e-8f) return false;
        const float distance = dot(s.screen_position_width.xyz - s.camera_position_focal.xyz,
            screen_normal) / denominator;
        if (distance <= 0.0f) return false;
        const float3 point = s.camera_position_focal.xyz + ray * distance;
        float3 reflected = reflect(ray, screen_normal);
        if (s.environment.z > 0.5f) {
            const float radius = s.environment.w;
            const float b = dot(point, reflected);
            const float c = dot(point, point) - radius * radius;
            const float discriminant = b * b - c;
            if (discriminant <= 0.0f) return false;
            const float t = -b + sqrt(discriminant);
            if (t <= 0.0f) return false;
            reflected = normalize(point + reflected * t);
        }
        const float3 source = rotate_environment(reflected, s.environment.x, s.environment.y);
        uv = float2(atan2(source.x, source.z) / (2.0f * M_PI_F) + 0.5f,
            0.5f - asin(clamp(source.y, -1.0f, 1.0f)) / M_PI_F);
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

    inline bool reference_uv(
        uint2 p, constant SetupParameters& s, thread float2& uv
    ) {
        const float2 output_size = float2(s.raster.xy);
        const float2 reference_size = float2(s.reference_raster.xy);
        const float2 output_pixel = (float2(p) + 0.5f)
            * output_size / float2(s.preview_raster.xy) - 0.5f;
        const uint placement = s.reference_raster.z;
        if (placement == 2u) {
            uv = (output_pixel + 0.5f) / output_size;
            return true;
        }
        const float scale = placement == 0u
            ? min(output_size.x / reference_size.x, output_size.y / reference_size.y)
            : (placement == 1u
                ? max(output_size.x / reference_size.x, output_size.y / reference_size.y)
                : 1.0f);
        const float2 offset = (output_size - reference_size * scale) * 0.5f;
        const float2 reference_pixel = (output_pixel - offset) / scale;
        uv = (reference_pixel + 0.5f) / reference_size;
        return all(uv >= 0.0f) && all(uv <= 1.0f);
    }

    inline float device_coverage(
        uint2 p, bool apply_lens_distortion, constant SetupParameters& s
    ) {
        constexpr float OFFSETS[4] = {0.125f, 0.375f, 0.625f, 0.875f};
        float covered = 0.0f;
        for (uint y = 0; y < 4; ++y) {
            for (uint x = 0; x < 4; ++x) {
                float2 camera;
                float2 panel;
                if (!camera_uv_at(float2(p) + float2(OFFSETS[x], OFFSETS[y]), s, camera)) {
                    continue;
                }
                bool valid;
                if (apply_lens_distortion) {
                    float unused_depth;
                    valid = focus_screen_sample(camera, s, panel, unused_depth);
                } else {
                    valid = screen_uv(camera, s, panel);
                }
                if (valid && all(panel >= 0.0f) && all(panel <= 1.0f)) covered += 1.0f;
            }
        }
        return covered * (1.0f / 16.0f);
    }

    kernel void setup_framing(
        texture2d<float, access::sample> source [[texture(0)]],
        texture2d<float, access::write> output [[texture(1)]],
        texture2d<float, access::sample> reference [[texture(2)]],
        sampler linear_sampler [[sampler(0)]],
        constant SetupParameters& s [[buffer(0)]],
        uint2 p [[thread_position_in_grid]]
    ) {
        if (any(p >= s.preview_raster.xy)) return;
        float2 referenceUV;
        const bool hasReference = reference_uv(p, s, referenceUV);
        const float4 background = (s.modes.w == 3u || s.modes.w == 4u || s.modes.w == 5u)
            ? (hasReference
                ? reference.sample(linear_sampler, referenceUV)
                : float4(0, 0, 0, 1))
            : (s.modes.z == 0 ? float4(0) : float4(0, 0, 0, 1));
        float2 camera;
        if (!camera_uv(p, s, camera)) { output.write(background, p); return; }
        if (s.modes.w == 4u || s.modes.w == 5u) {
            float2 panel;
            float unused_depth;
            float2 delivery;
            const bool center_valid = focus_screen_sample(camera, s, panel, unused_depth)
                && (s.modes.w == 5u
                    ? true
                    : delivery_uv(camera, s, delivery));
            const float coverage = device_coverage(p, true, s);
            if (!center_valid || coverage == 0.0f) {
                output.write(background, p); return;
            }
            if (s.modes.w == 5u) {
                delivery = (float2(p) + 0.5f) / float2(s.preview_raster.xy);
            }
            float4 value = source.sample(linear_sampler, delivery);
            value.a = 1.0f;
            output.write(mix(background, value, coverage), p);
            return;
        }
        if (s.modes.w == 1u) {
            float2 environmentUV;
            if (!environment_uv(camera, s, environmentUV)) {
                output.write(background, p); return;
            }
            float4 reflected = source.sample(linear_sampler, environmentUV);
            reflected.a = 1.0f;
            output.write(reflected, p);
            return;
        }
        if (s.modes.w == 2u) {
            float2 panel;
            float depth;
            if (!focus_screen_sample(camera, s, panel, depth)
                || any(panel < 0.0f) || any(panel > 1.0f)) {
                output.write(background, p); return;
            }
            const float focal_m = s.camera_position_focal.w * 0.001f;
            const float focus_m = s.lens_tangential_focus.y;
            const float f_stop = s.lens_tangential_focus.z;
            const float denominator = max(1.0e-8f, f_stop * depth * (focus_m - focal_m));
            const float coc_m = focal_m * focal_m * abs(depth - focus_m) / denominator;
            const float pixel_pitch_m = s.camera_right_sensor_width.w * 0.001f
                / float(s.raster.z);
            const float coc_pixels = coc_m / max(1.0e-9f, pixel_pitch_m);
            const float focus_value = 1.0f / (1.0f + 0.25f * coc_pixels * coc_pixels);
            const float2 grid_phase = abs(fract(panel * float2(12, 8) + 0.5f) - 0.5f);
            const bool grid = min(grid_phase.x, grid_phase.y) < 0.018f;
            output.write(grid ? float4(1, 0, 0, 1)
                : float4(focus_value, focus_value, focus_value, 1), p);
            return;
        }
        float2 panel;
        if (s.modes.w == 3u) {
            float unused_depth;
            if (!focus_screen_sample(camera, s, panel, unused_depth)) {
                output.write(background, p); return;
            }
        } else if (!screen_uv(camera, s, panel)) {
            output.write(background, p); return;
        }
        const bool inside = all(panel >= 0.0f) && all(panel <= 1.0f);
        const float coverage = (s.modes.w == 3u)
            ? device_coverage(p, true, s)
            : (s.modes.w == 0u ? device_coverage(p, false, s) : (inside ? 1.0f : 0.0f));
        if (coverage == 0.0f) { output.write(background, p); return; }

        const float2 uv = source_uv(clamp(panel, 0.0f, 1.0f), s);
        if (any(uv < 0.0f) || any(uv > 1.0f)) {
            output.write(float4(0, 0, 0, 1), p);
            return;
        }
        float4 value = source.sample(linear_sampler, uv);
        value.a = 1.0f;
        const float opacity = coverage * (s.modes.w == 3u ? 0.72f : 1.0f);
        output.write(mix(background, value, opacity), p);
    }
    """#
}
