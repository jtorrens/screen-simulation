import Foundation
import Metal
import simd
import ScreenPhysicalBridge
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
        /// Capture-sensor gate mapped into the Delivery Raster.
        let sensorGateBoundary: [CGPoint]
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
        var environmentCenter: SIMD4<Float>
        var environmentPlacementAnchor: SIMD4<Float>
        var environmentPlacementSourceScale: SIMD4<Float>
        var environmentPlacementTangent: SIMD4<Float>
        var environmentFraming: SIMD4<Float>
        var lensRadialTangential: SIMD4<Float>
        var lensTangentialFocus: SIMD4<Float>
        var presentation: SIMD4<UInt32>
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
        plan: ScreenSetupDiagnosticPlanV1,
        diagnosticMode: UInt32 = 0,
        environmentFraming: SIMD4<Float> = SIMD4(0.5, 0.5, 1, 0),
        interactiveBackground: InteractivePreviewBackground? = nil
    ) throws -> Result {
        let deliveryWidth = Int(plan.delivery_width)
        let deliveryHeight = Int(plan.delivery_height)
        let outputWidth = Int(plan.preview_width)
        let outputHeight = Int(plan.preview_height)
        guard plan.abi_version == SCREEN_PHYSICAL_FRAME_ABI_VERSION,
              deliveryWidth > 0, deliveryHeight > 0,
              outputWidth > 0, outputHeight > 0,
              plan.active_sensor_width > 0, plan.active_sensor_height > 0,
              plan.device_native_width > 0, plan.device_native_height > 0,
              plan.device_active_width_meters > 0,
              plan.device_active_height_meters > 0,
              plan.sensor_width_millimeters > 0,
              plan.sensor_height_millimeters > 0,
              plan.focal_length_millimeters > 0,
              plan.delivery_placement <= 2,
              plan.delivery_background <= 1
        else { throw SetupFramingError.invalidContract }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: source.texture.pixelFormat == .rgba32Float
                ? .rgba32Float : .rgba16Float,
            width: outputWidth,
            height: outputHeight,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        guard let output = source.texture.device.makeTexture(descriptor: descriptor),
              let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder()
        else { throw SetupFramingError.unavailableMetal }

        let cameraQ = [
            plan.camera_rotation_xyzw.0, plan.camera_rotation_xyzw.1,
            plan.camera_rotation_xyzw.2, plan.camera_rotation_xyzw.3,
        ]
        let right = Self.rotate([1, 0, 0], by: cameraQ)
        let up = Self.rotate([0, 1, 0], by: cameraQ)
        let forward = Self.rotate([0, 0, -1], by: cameraQ)
        let deliveryPlacement = plan.delivery_placement
        var parameters = Parameters(
            cameraPositionFocal: SIMD4(
                plan.camera_position.0, plan.camera_position.1,
                plan.camera_position.2, plan.focal_length_millimeters
            ),
            cameraRightSensorWidth: SIMD4(
                right.x, right.y, right.z, plan.sensor_width_millimeters
            ),
            cameraUpSensorHeight: SIMD4(
                up.x, up.y, up.z, plan.sensor_height_millimeters
            ),
            cameraForward: SIMD4(forward.x, forward.y, forward.z, 0),
            screenPositionWidth: SIMD4(
                plan.screen_position.0, plan.screen_position.1,
                plan.screen_position.2, plan.device_active_width_meters
            ),
            screenQuaternion: SIMD4(
                plan.screen_rotation_xyzw.0, plan.screen_rotation_xyzw.1,
                plan.screen_rotation_xyzw.2, plan.screen_rotation_xyzw.3
            ),
            screenHeightShiftY: SIMD4(
                plan.device_active_height_meters, plan.lens_shift.1,
                plan.device_corner_radius_meters, 0
            ),
            raster: SIMD4(
                UInt32(deliveryWidth), UInt32(deliveryHeight),
                plan.active_sensor_width, plan.active_sensor_height
            ),
            previewRaster: SIMD4(UInt32(outputWidth), UInt32(outputHeight), 0, 0),
            sourceDevice: SIMD4(
                UInt32(source.width), UInt32(source.height),
                plan.device_native_width, plan.device_native_height
            ),
            referenceRaster: SIMD4(
                UInt32(reference?.width ?? source.width),
                UInt32(reference?.height ?? source.height),
                Self.sourcePlacement(referencePlacement),
                reference == nil ? 0 : 1
            ),
            modes: SIMD4(
                Self.sourcePlacement(sourcePlacement),
                deliveryPlacement,
                plan.delivery_background,
                diagnosticMode
            ),
            environment: SIMD4(
                0,
                0,
                plan.environment_finite_sphere ? 1 : 0,
                plan.environment_sphere_radius_meters
            ),
            environmentCenter: SIMD4(
                plan.environment_sphere_center_meters.0,
                plan.environment_sphere_center_meters.1,
                plan.environment_sphere_center_meters.2, 0
            ),
            environmentPlacementAnchor: SIMD4(
                plan.environment_placement_anchor_direction_world.0,
                plan.environment_placement_anchor_direction_world.1,
                plan.environment_placement_anchor_direction_world.2, 0
            ),
            environmentPlacementSourceScale: SIMD4(
                plan.environment_placement_source_direction.0,
                plan.environment_placement_source_direction.1,
                plan.environment_placement_source_direction.2,
                0
            ),
            environmentPlacementTangent: SIMD4(
                plan.environment_placement_tangent_transform.0,
                plan.environment_placement_tangent_transform.1,
                plan.environment_placement_tangent_transform.2,
                plan.environment_placement_tangent_transform.3
            ),
            environmentFraming: environmentFraming,
            lensRadialTangential: SIMD4(
                plan.lens_radial_distortion.0,
                plan.lens_radial_distortion.1,
                plan.lens_radial_distortion.2,
                plan.lens_tangential_distortion.0
            ),
            lensTangentialFocus: SIMD4(
                plan.lens_tangential_distortion.1,
                plan.focus_distance_meters,
                plan.f_stop, 0
            ),
            presentation: SIMD4(interactiveBackground?.rendererCode ?? 0, 0, 0, 0)
        )
        parameters.cameraForward.w = plan.lens_shift.0

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
            plan: plan,
            applyLensDistortion: diagnosticMode == 2 || diagnosticMode == 3 || diagnosticMode == 4,
            sampleDistortedEdges: diagnosticMode == 2 || diagnosticMode == 3 || diagnosticMode == 4,
            roundedOutline: true
        )
        let corners = Self.projectedBoundary(
            plan: plan,
            applyLensDistortion: diagnosticMode == 2 || diagnosticMode == 3 || diagnosticMode == 4,
            sampleDistortedEdges: false,
            roundedOutline: false
        )
        let sensorGateBoundary = Self.sensorGateBoundary(
            cameraWidth: Int(plan.active_sensor_width),
            cameraHeight: Int(plan.active_sensor_height),
            deliveryWidth: deliveryWidth,
            deliveryHeight: deliveryHeight,
            deliveryPlacement: deliveryPlacement,
            outputWidth: outputWidth,
            outputHeight: outputHeight
        )
        return Result(
            frame: frame,
            boundary: boundary,
            sensorGateBoundary: sensorGateBoundary,
            corners: corners
        )
    }

    func renderReferenceMatch(
        source: StudioColorMetalFrame,
        reference: StudioColorMetalFrame,
        sourcePlacement: WorkspaceModel.SourcePlacement,
        referencePlacement: WorkspaceModel.SourcePlacement,
        plan: ScreenSetupDiagnosticPlanV1
    ) throws -> Result {
        try render(
            source: source,
            reference: reference,
            sourcePlacement: sourcePlacement,
            referencePlacement: referencePlacement,
            plan: plan,
            diagnosticMode: 3
        )
    }

    func renderReferenceComposite(
        cameraResult: StudioColorMetalFrame,
        reference: StudioColorMetalFrame,
        referencePlacement: WorkspaceModel.SourcePlacement,
        plan: ScreenSetupDiagnosticPlanV1,
        deliveryAligned: Bool = false
    ) throws -> Result {
        try renderCameraComposite(
            cameraResult: cameraResult,
            reference: reference,
            referencePlacement: referencePlacement,
            plan: plan,
            deliveryAligned: deliveryAligned
        )
    }

    func renderCameraComposite(
        cameraResult: StudioColorMetalFrame,
        reference: StudioColorMetalFrame?,
        referencePlacement: WorkspaceModel.SourcePlacement,
        plan: ScreenSetupDiagnosticPlanV1,
        deliveryAligned: Bool = false,
        interactiveBackground: InteractivePreviewBackground? = nil
    ) throws -> Result {
        try render(
            source: cameraResult,
            reference: reference,
            sourcePlacement: .stretch,
            referencePlacement: referencePlacement,
            plan: plan,
            diagnosticMode: deliveryAligned ? 5 : 4,
            interactiveBackground: interactiveBackground
        )
    }

    func renderEnvironment(
        environment: StudioColorMetalFrame,
        plan: ScreenSetupDiagnosticPlanV1,
        planarFraming: SIMD4<Float>? = nil
    ) throws -> Result {
        try render(
            source: environment,
            sourcePlacement: .stretch,
            referencePlacement: .stretch,
            plan: plan,
            diagnosticMode: planarFraming == nil ? 1 : 6,
            environmentFraming: planarFraming ?? SIMD4(0.5, 0.5, 1, 0)
        )
    }

    func renderFocus(
        source: StudioColorMetalFrame,
        reference: StudioColorMetalFrame? = nil,
        referencePlacement: WorkspaceModel.SourcePlacement = .stretch,
        plan: ScreenSetupDiagnosticPlanV1,
        interactiveBackground: InteractivePreviewBackground? = nil
    ) throws -> Result {
        try render(
            source: source, reference: reference,
            sourcePlacement: .stretch,
            referencePlacement: referencePlacement, plan: plan,
            diagnosticMode: 2,
            interactiveBackground: interactiveBackground
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

    static func sensorGateBoundary(
        cameraWidth: Int,
        cameraHeight: Int,
        deliveryWidth: Int,
        deliveryHeight: Int,
        deliveryPlacement: UInt32,
        outputWidth: Int,
        outputHeight: Int
    ) -> [CGPoint] {
        guard cameraWidth > 0, cameraHeight > 0,
              deliveryWidth > 0, deliveryHeight > 0,
              outputWidth > 0, outputHeight > 0
        else { return [] }

        let cameraSize = SIMD2<Double>(Double(cameraWidth), Double(cameraHeight))
        let deliverySize = SIMD2<Double>(Double(deliveryWidth), Double(deliveryHeight))
        let scale: Double
        let offset: SIMD2<Double>
        switch deliveryPlacement {
        case 0, 2:
            scale = deliveryPlacement == 0
                ? min(deliverySize.x / cameraSize.x, deliverySize.y / cameraSize.y)
                : max(deliverySize.x / cameraSize.x, deliverySize.y / cameraSize.y)
            offset = (deliverySize - cameraSize * scale) * 0.5
        case 1:
            scale = 1
            // Match the integer-centered placement used by the Metal evaluator.
            offset = SIMD2(
                Double((deliveryWidth - cameraWidth) / 2),
                Double((deliveryHeight - cameraHeight) / 2)
            )
        default:
            return []
        }

        let previewScale = SIMD2<Double>(
            Double(outputWidth) / Double(deliveryWidth),
            Double(outputHeight) / Double(deliveryHeight)
        )
        let minimum = offset * previewScale - 0.5
        let maximum = (offset + cameraSize * scale) * previewScale - 0.5
        return [
            CGPoint(x: minimum.x, y: minimum.y),
            CGPoint(x: maximum.x, y: minimum.y),
            CGPoint(x: maximum.x, y: maximum.y),
            CGPoint(x: minimum.x, y: maximum.y),
        ]
    }

    private static func projectedBoundary(
        plan: ScreenSetupDiagnosticPlanV1,
        applyLensDistortion: Bool,
        sampleDistortedEdges: Bool,
        roundedOutline: Bool
    ) -> [CGPoint] {
        let perimeter: [(Float, Float)]
        if roundedOutline, plan.device_corner_radius_meters > 0 {
            let radiusX = plan.device_corner_radius_meters / plan.device_active_width_meters
            let radiusY = plan.device_corner_radius_meters / plan.device_active_height_meters
            let samplesPerCorner = sampleDistortedEdges ? 32 : 8
            let arcs: [(center: SIMD2<Float>, start: Float)] = [
                (SIMD2(1 - radiusX, radiusY), -.pi / 2),
                (SIMD2(1 - radiusX, 1 - radiusY), 0),
                (SIMD2(radiusX, 1 - radiusY), .pi / 2),
                (SIMD2(radiusX, radiusY), .pi),
            ]
            perimeter = arcs.flatMap { arc in
                (0..<samplesPerCorner).map { sample in
                    let angle = arc.start + Float(sample) / Float(samplesPerCorner) * (.pi / 2)
                    return (
                        arc.center.x + cos(angle) * radiusX,
                        arc.center.y + sin(angle) * radiusY
                    )
                }
            }
        } else {
            let edgeSamples = sampleDistortedEdges ? 64 : 1
            let corners: [(Float, Float)] = [(0, 0), (1, 0), (1, 1), (0, 1)]
            perimeter = corners.indices.flatMap { edge -> [(Float, Float)] in
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
        }
        return perimeter.compactMap { u, v in
            projectedDevicePoint(
                u: u, v: v,
                plan: plan,
                applyLensDistortion: applyLensDistortion
            )
        }
    }

    static func projectedDevicePoint(
        u: Float,
        v: Float,
        plan: ScreenSetupDiagnosticPlanV1,
        applyLensDistortion: Bool
    ) -> CGPoint? {
        let deliveryWidth = Int(plan.delivery_width)
        let deliveryHeight = Int(plan.delivery_height)
        let outputWidth = Int(plan.preview_width)
        let outputHeight = Int(plan.preview_height)
        let deliveryPlacement = plan.delivery_placement
        guard u.isFinite, v.isFinite, deliveryWidth > 0, deliveryHeight > 0,
              outputWidth > 0, outputHeight > 0 else { return nil }
        let cameraQ = [
            plan.camera_rotation_xyzw.0, plan.camera_rotation_xyzw.1,
            plan.camera_rotation_xyzw.2, plan.camera_rotation_xyzw.3,
        ]
        let screenQ = [
            plan.screen_rotation_xyzw.0, plan.screen_rotation_xyzw.1,
            plan.screen_rotation_xyzw.2, plan.screen_rotation_xyzw.3,
        ]
        let camera = SIMD3<Float>(
            plan.camera_position.0, plan.camera_position.1, plan.camera_position.2
        )
        let screen = SIMD3<Float>(
            plan.screen_position.0, plan.screen_position.1, plan.screen_position.2
        )
        let cameraRight = rotate([1, 0, 0], by: cameraQ)
        let cameraUp = rotate([0, 1, 0], by: cameraQ)
        let cameraForward = rotate([0, 0, -1], by: cameraQ)
        let screenRight = rotate([1, 0, 0], by: screenQ)
        let screenUp = rotate([0, 1, 0], by: screenQ)
        let cameraSize = SIMD2<Float>(
            Float(plan.active_sensor_width), Float(plan.active_sensor_height)
        )
        let outputSize = SIMD2<Float>(Float(deliveryWidth), Float(deliveryHeight))
        let scale: Float = switch deliveryPlacement {
        case 0: min(outputSize.x / cameraSize.x, outputSize.y / cameraSize.y)
        case 2: max(outputSize.x / cameraSize.x, outputSize.y / cameraSize.y)
        default: 1
        }
        let offset = (outputSize - cameraSize * scale) * 0.5
        let focal = plan.focal_length_millimeters
        let sensorWidth = plan.sensor_width_millimeters
        let sensorHeight = plan.sensor_height_millimeters
        let shiftX = plan.lens_shift.0
        let shiftY = plan.lens_shift.1
        let world = screen
            + screenRight * ((u - 0.5) * plan.device_active_width_meters)
            + screenUp * ((0.5 - v) * plan.device_active_height_meters)
        let relative = world - camera
        let depth = simd_dot(relative, cameraForward)
        guard depth > 0 else { return nil }
        let idealX = simd_dot(relative, cameraRight) / depth * (2 * focal / sensorWidth)
        let idealY = simd_dot(relative, cameraUp) / depth * (2 * focal / sensorHeight)
        let distorted = applyLensDistortion
            ? Self.distort(
                SIMD2(idealX, idealY),
                radial: Self.radial(plan),
                tangential: Self.tangential(plan)
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

    static func deviceUV(
        at point: CGPoint,
        plan: ScreenSetupDiagnosticPlanV1
    ) -> SIMD2<Double>? {
        let deliveryWidth = Int(plan.delivery_width)
        let deliveryHeight = Int(plan.delivery_height)
        let outputWidth = Int(plan.preview_width)
        let outputHeight = Int(plan.preview_height)
        let deliveryPlacement = plan.delivery_placement
        guard deliveryWidth > 0, deliveryHeight > 0, outputWidth > 0, outputHeight > 0 else {
            return nil
        }
        let cameraSize = SIMD2<Float>(
            Float(plan.active_sensor_width), Float(plan.active_sensor_height)
        )
        let outputSize = SIMD2<Float>(Float(deliveryWidth), Float(deliveryHeight))
        let previewScale = SIMD2<Float>(Float(outputWidth) / outputSize.x, Float(outputHeight) / outputSize.y)
        let outputPixel = (SIMD2(Float(point.x), Float(point.y)) + 0.5) / previewScale - 0.5
        let scale: Float = switch deliveryPlacement {
        case 0: min(outputSize.x / cameraSize.x, outputSize.y / cameraSize.y)
        case 2: max(outputSize.x / cameraSize.x, outputSize.y / cameraSize.y)
        default: 1
        }
        let offset = (outputSize - cameraSize * scale) * 0.5
        let cameraPixel = deliveryPlacement == 1
            ? outputPixel - offset
            : (outputPixel + 0.5 - offset) / scale - 0.5
        let cameraUV = (cameraPixel + 0.5) / cameraSize
        guard cameraUV.x.isFinite, cameraUV.y.isFinite else { return nil }
        let observed = cameraUV * 2 - 1
        let shifted = SIMD2<Float>(
            observed.x + 2 * plan.lens_shift.0,
            -observed.y - 2 * plan.lens_shift.1
        )
        guard let ideal = inverseDistortion(
            shifted,
            radial: Self.radial(plan),
            tangential: Self.tangential(plan)
        ) else { return nil }
        let cameraQ = [
            plan.camera_rotation_xyzw.0, plan.camera_rotation_xyzw.1,
            plan.camera_rotation_xyzw.2, plan.camera_rotation_xyzw.3,
        ]
        let screenQ = [
            plan.screen_rotation_xyzw.0, plan.screen_rotation_xyzw.1,
            plan.screen_rotation_xyzw.2, plan.screen_rotation_xyzw.3,
        ]
        let camera = SIMD3<Float>(
            plan.camera_position.0, plan.camera_position.1, plan.camera_position.2
        )
        let screen = SIMD3<Float>(
            plan.screen_position.0, plan.screen_position.1, plan.screen_position.2
        )
        let cameraRight = rotate([1, 0, 0], by: cameraQ)
        let cameraUp = rotate([0, 1, 0], by: cameraQ)
        let cameraForward = rotate([0, 0, -1], by: cameraQ)
        let screenRight = rotate([1, 0, 0], by: screenQ)
        let screenUp = rotate([0, 1, 0], by: screenQ)
        let screenNormal = rotate([0, 0, 1], by: screenQ)
        let ray = simd_normalize(
            cameraForward
                + cameraRight * (ideal.x * plan.sensor_width_millimeters
                    / (2 * plan.focal_length_millimeters))
                + cameraUp * (ideal.y * plan.sensor_height_millimeters
                    / (2 * plan.focal_length_millimeters))
        )
        let denominator = simd_dot(ray, screenNormal)
        guard abs(denominator) >= 1e-8 else { return nil }
        let distance = simd_dot(screen - camera, screenNormal) / denominator
        guard distance > 0 else { return nil }
        let local = camera + ray * distance - screen
        let uv = SIMD2<Double>(
            Double(simd_dot(local, screenRight) / plan.device_active_width_meters + 0.5),
            Double(0.5 - simd_dot(local, screenUp) / plan.device_active_height_meters)
        )
        guard Self.roundedDeviceContains(uv, plan: plan) else { return nil }
        return uv
    }

    private static func roundedDeviceContains(
        _ uv: SIMD2<Double>, plan: ScreenSetupDiagnosticPlanV1
    ) -> Bool {
        guard uv.x >= 0, uv.x <= 1, uv.y >= 0, uv.y <= 1 else { return false }
        guard plan.device_corner_radius_meters > 0 else { return true }
        let radius = SIMD2(
            Double(plan.device_corner_radius_meters / plan.device_active_width_meters),
            Double(plan.device_corner_radius_meters / plan.device_active_height_meters)
        )
        let q = simd_max(abs(uv - 0.5) - (SIMD2(repeating: 0.5) - radius), .zero)
        let normalized = q / radius
        return simd_dot(normalized, normalized) <= 1
    }

    private static func radial(_ plan: ScreenSetupDiagnosticPlanV1) -> [Double] {
        [
            Double(plan.lens_radial_distortion.0),
            Double(plan.lens_radial_distortion.1),
            Double(plan.lens_radial_distortion.2),
        ]
    }

    private static func tangential(_ plan: ScreenSetupDiagnosticPlanV1) -> [Double] {
        [
            Double(plan.lens_tangential_distortion.0),
            Double(plan.lens_tangential_distortion.1),
        ]
    }

    private static func inverseDistortion(
        _ observed: SIMD2<Float>, radial: [Double], tangential: [Double]
    ) -> SIMD2<Float>? {
        var ideal = observed
        for _ in 0..<12 {
            let projected = distort(ideal, radial: radial, tangential: tangential)
            let residual = projected - observed
            if max(abs(residual.x), abs(residual.y)) < 1e-7 { break }
            let epsilon: Float = 1e-4
            let dx = (distort(ideal + SIMD2(epsilon, 0), radial: radial, tangential: tangential)
                - distort(ideal - SIMD2(epsilon, 0), radial: radial, tangential: tangential)) / (2 * epsilon)
            let dy = (distort(ideal + SIMD2(0, epsilon), radial: radial, tangential: tangential)
                - distort(ideal - SIMD2(0, epsilon), radial: radial, tangential: tangential)) / (2 * epsilon)
            let determinant = dx.x * dy.y - dy.x * dx.y
            guard abs(determinant) >= 1e-10 else { return nil }
            ideal -= SIMD2(
                (dy.y * residual.x - dy.x * residual.y) / determinant,
                (-dx.y * residual.x + dx.x * residual.y) / determinant
            )
        }
        let residual = abs(distort(ideal, radial: radial, tangential: tangential) - observed)
        return ideal.x.isFinite && ideal.y.isFinite && max(residual.x, residual.y) < 2e-4
            ? ideal : nil
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
        float4 environment_center;
        float4 environment_placement_anchor;
        float4 environment_placement_source_scale;
        float4 environment_placement_tangent;
        float4 environment_framing;
        float4 lens_radial_tangential;
        float4 lens_tangential_focus;
        uint4 presentation;
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

    inline void tangent_basis(float3 direction, thread float3& right, thread float3& up) {
        const float3 reference = abs(direction.y) < 0.999f
            ? float3(0, 1, 0) : float3(1, 0, 0);
        right = normalize(cross(reference, direction));
        up = normalize(cross(direction, right));
    }

    inline float2 complex_multiply(float2 left, float2 right) {
        return float2(left.x * right.x - left.y * right.y,
            left.x * right.y + left.y * right.x);
    }

    inline float2 complex_divide(float2 numerator, float2 denominator) {
        const float norm = max(dot(denominator, denominator), 1.0e-20f);
        return float2(dot(numerator, denominator),
            numerator.y * denominator.x - numerator.x * denominator.y) / norm;
    }

    inline float3 place_environment(float3 direction, constant SetupParameters& s) {
        const float3 anchor = normalize(s.environment_placement_anchor.xyz);
        const float3 source = normalize(s.environment_placement_source_scale.xyz);
        const float worldAngle = acos(clamp(dot(anchor, direction), -1.0f, 1.0f));
        const float worldRadius = tan(worldAngle * 0.5f);
        if (worldRadius <= 1.0e-7f) return source;
        float3 anchorRight, anchorUp;
        tangent_basis(anchor, anchorRight, anchorUp);
        float3 tangent = direction - anchor * dot(direction, anchor);
        tangent = dot(tangent, tangent) > 1.0e-12f ? normalize(tangent) : anchorRight;
        const float2 point = worldRadius * float2(
            dot(tangent, anchorRight), dot(tangent, anchorUp));
        const float4 transform = s.environment_placement_tangent;
        const float2 mappedPoint = complex_divide(
            complex_multiply(transform.xy, point),
            float2(1.0f, 0.0f) + complex_multiply(transform.zw, point));
        const float mappedRadius = length(mappedPoint);
        if (!isfinite(mappedRadius) || mappedRadius <= 1.0e-8f) return source;
        const float angle = 2.0f * atan(mappedRadius);
        float3 sourceRight, sourceUp;
        tangent_basis(source, sourceRight, sourceUp);
        const float3 mapped = normalize(
            sourceRight * mappedPoint.x + sourceUp * mappedPoint.y);
        return normalize(source * cos(angle) + mapped * sin(angle));
    }

    inline bool environment_uv(float2 camera_uv, constant SetupParameters& s, thread float2& uv) {
        const float3 ray = camera_ray(camera_uv, s);
        const float3 screen_right = rotate_q(s.screen_quaternion, float3(1, 0, 0));
        const float3 screen_up = rotate_q(s.screen_quaternion, float3(0, 1, 0));
        const float3 screen_normal = rotate_q(s.screen_quaternion, float3(0, 0, 1));
        const float denominator = dot(ray, screen_normal);
        if (abs(denominator) < 1.0e-8f) return false;
        const float distance = dot(s.screen_position_width.xyz - s.camera_position_focal.xyz,
            screen_normal) / denominator;
        if (distance <= 0.0f) return false;
        const float3 point = s.camera_position_focal.xyz + ray * distance;
        const float3 relative = point - s.screen_position_width.xyz;
        const float3 local_point = float3(
            dot(relative, screen_right), dot(relative, screen_up), dot(relative, screen_normal));
        const float3 reflected_world = reflect(ray, screen_normal);
        float3 reflected = reflected_world;
        if (s.environment.z > 0.5f) {
            const float radius = s.environment.w;
            const float3 relative_point = point - s.environment_center.xyz;
            const float b = dot(relative_point, reflected);
            const float c = dot(relative_point, relative_point) - radius * radius;
            const float discriminant = b * b - c;
            if (discriminant <= 0.0f) return false;
            const float t = -b + sqrt(discriminant);
            if (t <= 0.0f) return false;
            reflected = normalize(relative_point + reflected * t);
        }
        const float3 source = place_environment(normalize(reflected), s);
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

    inline bool framed_environment_uv(
        float2 device_uv, constant SetupParameters& s, thread float2& uv
    ) {
        const float angle = -s.environment_framing.w;
        const float sn = sin(angle), cs = cos(angle);
        const float2 centered = device_uv - 0.5f;
        const float2 rotated = float2(
            centered.x * cs - centered.y * sn,
            centered.x * sn + centered.y * cs
        );
        const float source_aspect = float(s.source_device.x) / float(s.source_device.y);
        const float device_aspect = float(s.source_device.z) / float(s.source_device.w);
        const float2 fit_scale = source_aspect > device_aspect
            ? float2(1.0f, source_aspect / device_aspect)
            : float2(device_aspect / source_aspect, 1.0f);
        uv = s.environment_framing.xy
            + rotated * fit_scale / s.environment_framing.z;
        return all(uv >= 0.0f) && all(uv <= 1.0f);
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

    inline float4 interactive_background(
        uint2 p,
        bool has_reference,
        float2 reference_uv_value,
        texture2d<float, access::sample> reference,
        sampler linear_sampler,
        constant SetupParameters& s
    ) {
        const uint mode = s.presentation.x;
        if (mode == 1u) {
            return has_reference
                ? reference.sample(linear_sampler, reference_uv_value)
                : float4(0, 0, 0, 1);
        }
        if (mode == 2u) {
            // Fixed in Delivery Raster pixels so Fit/interactive preview scaling
            // never changes the authored inspection pattern.
            const float2 delivery_pixel = (float2(p) + 0.5f)
                * float2(s.raster.xy) / float2(s.preview_raster.xy);
            const uint2 tile = uint2(floor(delivery_pixel / 32.0f));
            const float level = ((tile.x + tile.y) & 1u) == 0u ? 1.0f : 0.18f;
            return float4(level, level, level, 1);
        }
        if (mode == 3u) return float4(0, 0, 0, 1);
        if (mode == 4u) return float4(1, 1, 1, 1);
        if (mode == 5u) return float4(0.18f, 0.18f, 0.18f, 1);
        return float4(0);
    }

    inline bool rounded_device_contains(float2 panel, constant SetupParameters& s) {
        if (any(panel < 0.0f) || any(panel > 1.0f)) return false;
        const float radius_meters = s.screen_height_shift_y.z;
        if (radius_meters <= 0.0f) return true;
        const float2 radius = radius_meters
            / float2(s.screen_position_width.w, s.screen_height_shift_y.x);
        const float2 q = abs(panel - 0.5f) - (0.5f - radius);
        const float2 normalized = max(q, 0.0f) / radius;
        return dot(normalized, normalized) <= 1.0f;
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
                if (valid && rounded_device_contains(panel, s)) covered += 1.0f;
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
        const bool referenceComposite =
            (s.modes.w == 3u || s.modes.w == 4u || s.modes.w == 5u)
            && s.reference_raster.w != 0u;
        const float4 background = s.presentation.x != 0u
            ? interactive_background(
                p,
                hasReference && s.reference_raster.w != 0u,
                referenceUV,
                reference,
                linear_sampler,
                s)
            : (referenceComposite
                ? (hasReference
                    ? reference.sample(linear_sampler, referenceUV)
                    : float4(0, 0, 0, 1))
                : (s.modes.z == 0 ? float4(0) : float4(0, 0, 0, 1)));
        float2 camera;
        if (!camera_uv(p, s, camera)) { output.write(background, p); return; }
        if (s.modes.w == 4u || s.modes.w == 5u) {
            float2 delivery;
            const bool delivery_valid = s.modes.w == 5u
                ? true
                : delivery_uv(camera, s, delivery);
            if (!delivery_valid) {
                output.write(background, p); return;
            }
            if (s.modes.w == 5u) {
                delivery = (float2(p) + 0.5f) / float2(s.preview_raster.xy);
            }
            const float4 value = source.sample(linear_sampler, delivery);
            // The physical evaluator owns both outputs of Device VFX Transparency:
            // premultiplied additive device light in RGB and its transported
            // occlusion matte in alpha. Geometry here must not reconstruct a
            // second matte, because transparent authored Device regions can
            // intentionally reveal the reference plate.
            const float matte = clamp(value.a, 0.0f, 1.0f);
            output.write(float4(
                value.rgb + background.rgb * (1.0f - matte),
                1.0f
            ), p);
            return;
        }
        if (s.modes.w == 1u) {
            float2 environmentUV;
            if (!environment_uv(camera, s, environmentUV)) {
                output.write(background, p); return;
            }
            float4 reflected = source.sample(linear_sampler, environmentUV);
            constexpr float OUTSIDE_DEVICE_GAIN = 0.20f;
            const float coverage = device_coverage(p, false, s);
            reflected.rgb *= mix(OUTSIDE_DEVICE_GAIN, 1.0f, coverage);
            reflected.a = 1.0f;
            output.write(reflected, p);
            return;
        }
        if (s.modes.w == 6u) {
            float2 panel;
            if (!screen_uv(camera, s, panel)) {
                output.write(float4(0, 0, 0, 1), p); return;
            }
            float2 framedUV;
            if (!framed_environment_uv(panel, s, framedUV)) {
                output.write(float4(0, 0, 0, 1), p); return;
            }
            float4 value = source.sample(linear_sampler, framedUV);
            constexpr float OUTSIDE_DEVICE_GAIN = 0.20f;
            const float coverage = device_coverage(p, false, s);
            value.rgb *= mix(OUTSIDE_DEVICE_GAIN, 1.0f, coverage);
            value.a = 1.0f;
            output.write(value, p);
            return;
        }
        if (s.modes.w == 2u) {
            float2 panel;
            float depth;
            if (!focus_screen_sample(camera, s, panel, depth)
                || !rounded_device_contains(panel, s)) {
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
        const bool inside = rounded_device_contains(panel, s);
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
