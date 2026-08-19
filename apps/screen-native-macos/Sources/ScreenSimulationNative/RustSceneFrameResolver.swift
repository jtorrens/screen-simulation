import Foundation
import CoreGraphics
import ScreenPhysicalBridge

/// Owns the only executable scene resolver. Swift may author complete constant values and tracks,
/// but it cannot sample or combine them after this boundary.
final class RustSceneFrameResolver: @unchecked Sendable {
    let reference: ScreenSceneFrameResolverV1Ref

    init(
        revision: UInt64,
        frameRate: ExactFrameRate,
        base: PhysicalPipelineAuthoringState,
        resolvedDevice: ResolvedDevice,
        resolvedPipeline: PhysicalPipelineResolvedState,
        trackingCamera: TrackingCamera?,
        trackingMetersPerSourceUnit: Double?,
        autofocusEnabled: Bool = false,
        autofocusTargetU: Double = 0.5,
        autofocusTargetV: Double = 0.5
    ) throws {
        var error: UnsafePointer<CChar>?
        let cameraKnots = try Self.cameraKnots(
            base: base,
            trackingCamera: trackingCamera,
            trackingMetersPerSourceUnit: trackingMetersPerSourceUnit
        )
        let intrinsicsKnots = try Self.intrinsicsKnots(
            resolvedPipeline: resolvedPipeline,
            trackingCamera: trackingCamera
        )
        let screenKnots = [Self.poseKnot(
            timeNumerator: 0,
            timeDenominator: 1,
            position: base.screenPose.position,
            quaternion: base.screenPose.quaternion,
            interpolation: UInt32(SCREEN_PHYSICAL_POSE_HOLD.rawValue)
        )]
        let cameraTrack = cameraKnots.withUnsafeBufferPointer {
            screen_physical_camera_pose_track_v2_create($0.baseAddress, $0.count, &error)
        }
        guard let cameraTrack else { throw Self.bridge(error, "Track de cámara no válido.") }
        defer { screen_physical_camera_pose_track_v2_release(cameraTrack) }
        let intrinsicsTrack = intrinsicsKnots.withUnsafeBufferPointer {
            screen_physical_camera_intrinsics_track_v1_create($0.baseAddress, $0.count, &error)
        }
        guard let intrinsicsTrack else { throw Self.bridge(error, "Track de óptica no válido.") }
        defer { screen_physical_camera_intrinsics_track_v1_release(intrinsicsTrack) }
        let screenTrack = screenKnots.withUnsafeBufferPointer {
            screen_physical_screen_pose_track_v2_create($0.baseAddress, $0.count, &error)
        }
        guard let screenTrack else { throw Self.bridge(error, "Track de Device no válido.") }
        defer { screen_physical_screen_pose_track_v2_release(screenTrack) }

        var deviceParameters = resolvedDevice.parameters
        guard let deviceProfile = screen_device_profile_create(&deviceParameters, &error) else {
            throw Self.bridge(error, "Device resuelto no válido.")
        }
        defer { screen_device_profile_release(deviceProfile) }
        var pipelineParameters = resolvedPipeline.parameters
        guard let pipeline = screen_physical_pipeline_snapshot_create(&pipelineParameters, &error) else {
            throw Self.bridge(error, "Pipeline resuelto no válido.")
        }
        defer { screen_physical_pipeline_snapshot_release(pipeline) }
        guard let resolver = screen_scene_frame_resolver_v1_create(
            revision,
            frameRate.numerator,
            frameRate.denominator,
            cameraTrack,
            intrinsicsTrack,
            screenTrack,
            deviceProfile,
            pipeline,
            autofocusEnabled,
            Float(autofocusTargetU),
            Float(autofocusTargetV),
            &error
        ) else {
            throw Self.bridge(error, "La escena completa no se ha podido materializar en Rust.")
        }
        reference = resolver
    }

    deinit {
        screen_scene_frame_resolver_v1_release(reference)
    }

    func resolve(_ frame: PhysicalFrameSelection) throws -> ScreenResolvedSceneFrameV1 {
        var output = ScreenResolvedSceneFrameV1()
        var error: UnsafePointer<CChar>?
        guard screen_scene_frame_resolver_v1_resolve(
            reference,
            frame.frameIndex,
            frame.timeNumerator,
            frame.timeDenominator,
            &output,
            &error
        ), output.abi_version == SCREEN_PHYSICAL_FRAME_ABI_VERSION else {
            throw Self.bridge(error, "Rust no ha resuelto el frame de escena.")
        }
        return output
    }

    func resolveTrackingOverlay(
        frame: PhysicalFrameSelection,
        sourcePoints: [SIMD3<Double>],
        metersPerSourceUnit: Double,
        deliveryWidth: Int,
        deliveryHeight: Int,
        previewWidth: Int,
        previewHeight: Int,
        deliveryPlacement: UInt32,
        expectedRevision: UInt64
    ) throws -> [CGPoint?] {
        guard metersPerSourceUnit.isFinite, metersPerSourceUnit > 0,
              deliveryWidth > 0, deliveryHeight > 0,
              previewWidth > 0, previewHeight > 0
        else { throw PhysicalContractError.invalidFrameTime }
        var request = ScreenTrackingOverlayRequestV1()
        request.abi_version = SCREEN_PHYSICAL_FRAME_ABI_VERSION
        request.frame_index = frame.frameIndex
        request.time_numerator = frame.timeNumerator
        request.time_denominator = frame.timeDenominator
        request.meters_per_source_unit = Float(metersPerSourceUnit)
        request.delivery_width = UInt32(deliveryWidth)
        request.delivery_height = UInt32(deliveryHeight)
        request.preview_width = UInt32(previewWidth)
        request.preview_height = UInt32(previewHeight)
        request.delivery_placement = deliveryPlacement
        let input = sourcePoints.map { point in
            var value = ScreenTrackingOverlayPointV1()
            value.source_position = (Float(point.x), Float(point.y), Float(point.z))
            return value
        }
        var output = Array(repeating: ScreenProjectedTrackingPointV1(), count: input.count)
        var identity = ScreenTrackingOverlayIdentityV1()
        var error: UnsafePointer<CChar>?
        let succeeded = input.withUnsafeBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                screen_tracking_overlay_v1_resolve(
                    reference,
                    &request,
                    inputBuffer.baseAddress,
                    inputBuffer.count,
                    outputBuffer.baseAddress,
                    &identity,
                    &error
                )
            }
        }
        guard succeeded,
              identity.revision == expectedRevision,
              identity.frame_index == frame.frameIndex,
              identity.time_numerator == frame.timeNumerator,
              identity.time_denominator == frame.timeDenominator
        else { throw Self.bridge(error, "Rust no ha resuelto el overlay del mismo frame.") }
        return output.map { value in
            value.visible ? CGPoint(x: CGFloat(value.pixel.0), y: CGFloat(value.pixel.1)) : nil
        }
    }

    func projectFocusTarget(
        frame: PhysicalFrameSelection,
        uv: CGPoint,
        deliveryWidth: Int,
        deliveryHeight: Int,
        previewWidth: Int,
        previewHeight: Int,
        deliveryPlacement: UInt32,
        expectedRevision: UInt64
    ) throws -> CGPoint? {
        var request = focusTargetRequest(
            frame: frame,
            deliveryWidth: deliveryWidth,
            deliveryHeight: deliveryHeight,
            previewWidth: previewWidth,
            previewHeight: previewHeight,
            deliveryPlacement: deliveryPlacement
        )
        var target = ScreenSceneFocusTargetV1()
        target.uv = (Float(uv.x), Float(uv.y))
        var identity = ScreenTrackingOverlayIdentityV1()
        var error: UnsafePointer<CChar>?
        guard screen_scene_focus_target_v1_project(
            reference, &request, &target, &identity, &error
        ), sceneIdentity(identity, matches: frame, revision: expectedRevision) else {
            throw Self.bridge(error, "Rust no ha proyectado el objetivo de foco del frame.")
        }
        return target.valid
            ? CGPoint(x: CGFloat(target.pixel.0), y: CGFloat(target.pixel.1)) : nil
    }

    func unprojectFocusTarget(
        frame: PhysicalFrameSelection,
        pixel: CGPoint,
        deliveryWidth: Int,
        deliveryHeight: Int,
        previewWidth: Int,
        previewHeight: Int,
        deliveryPlacement: UInt32,
        expectedRevision: UInt64
    ) throws -> CGPoint? {
        var request = focusTargetRequest(
            frame: frame,
            deliveryWidth: deliveryWidth,
            deliveryHeight: deliveryHeight,
            previewWidth: previewWidth,
            previewHeight: previewHeight,
            deliveryPlacement: deliveryPlacement
        )
        var target = ScreenSceneFocusTargetV1()
        target.pixel = (Float(pixel.x), Float(pixel.y))
        var identity = ScreenTrackingOverlayIdentityV1()
        var error: UnsafePointer<CChar>?
        guard screen_scene_focus_target_v1_unproject(
            reference, &request, &target, &identity, &error
        ), sceneIdentity(identity, matches: frame, revision: expectedRevision) else {
            throw Self.bridge(error, "Rust no ha resuelto el objetivo de foco del frame.")
        }
        return target.valid ? CGPoint(x: CGFloat(target.uv.0), y: CGFloat(target.uv.1)) : nil
    }

    func minimumEnvironmentRadius(
        frame: PhysicalFrameSelection,
        center: SIMD3<Double>,
        expectedRevision: UInt64
    ) throws -> Double {
        var request = ScreenSceneEnvironmentRadiusRequestV1()
        request.abi_version = SCREEN_PHYSICAL_FRAME_ABI_VERSION
        request.frame_index = frame.frameIndex
        request.time_numerator = frame.timeNumerator
        request.time_denominator = frame.timeDenominator
        request.center_meters = (Float(center.x), Float(center.y), Float(center.z))
        var radius: Float = 0
        var identity = ScreenTrackingOverlayIdentityV1()
        var error: UnsafePointer<CChar>?
        guard screen_scene_environment_minimum_radius_v1(
            reference, &request, &radius, &identity, &error
        ), sceneIdentity(identity, matches: frame, revision: expectedRevision),
        radius.isFinite, radius > 0 else {
            throw Self.bridge(error, "Rust no ha resuelto el radio del entorno para el frame.")
        }
        return Double(radius)
    }

    private func focusTargetRequest(
        frame: PhysicalFrameSelection,
        deliveryWidth: Int,
        deliveryHeight: Int,
        previewWidth: Int,
        previewHeight: Int,
        deliveryPlacement: UInt32
    ) -> ScreenSceneFocusTargetRequestV1 {
        var request = ScreenSceneFocusTargetRequestV1()
        request.abi_version = SCREEN_PHYSICAL_FRAME_ABI_VERSION
        request.frame_index = frame.frameIndex
        request.time_numerator = frame.timeNumerator
        request.time_denominator = frame.timeDenominator
        request.delivery_width = UInt32(deliveryWidth)
        request.delivery_height = UInt32(deliveryHeight)
        request.preview_width = UInt32(previewWidth)
        request.preview_height = UInt32(previewHeight)
        request.delivery_placement = deliveryPlacement
        return request
    }

    private func sceneIdentity(
        _ identity: ScreenTrackingOverlayIdentityV1,
        matches frame: PhysicalFrameSelection,
        revision: UInt64
    ) -> Bool {
        identity.revision == revision
            && identity.frame_index == frame.frameIndex
            && identity.time_numerator == frame.timeNumerator
            && identity.time_denominator == frame.timeDenominator
    }

    private static func cameraKnots(
        base: PhysicalPipelineAuthoringState,
        trackingCamera: TrackingCamera?,
        trackingMetersPerSourceUnit: Double?
    ) throws -> [ScreenPhysicalPoseKnotV2] {
        guard let trackingCamera else {
            return [poseKnot(
                timeNumerator: 0,
                timeDenominator: 1,
                position: base.cameraPose.position,
                quaternion: base.cameraPose.quaternion,
                interpolation: UInt32(SCREEN_PHYSICAL_POSE_HOLD.rawValue)
            )]
        }
        guard let scale = trackingMetersPerSourceUnit, scale.isFinite, scale > 0,
              !trackingCamera.samples.isEmpty else {
            throw PhysicalContractError.invalidFrameTime
        }
        return trackingCamera.samples.map { sample in
            poseKnot(
                timeNumerator: Int64(sample.frame) * Int64(trackingCamera.frameRateDenominator),
                timeDenominator: trackingCamera.frameRateNumerator,
                position: [
                    sample.sourcePosition.x * scale,
                    sample.sourcePosition.y * scale,
                    sample.sourcePosition.z * scale,
                ],
                quaternion: [
                    sample.orientation.x, sample.orientation.y,
                    sample.orientation.z, sample.orientation.w,
                ],
                interpolation: UInt32(SCREEN_PHYSICAL_POSE_LINEAR.rawValue)
            )
        }
    }

    private static func intrinsicsKnots(
        resolvedPipeline: PhysicalPipelineResolvedState,
        trackingCamera: TrackingCamera?
    ) throws -> [ScreenPhysicalCameraIntrinsicsKnotV1] {
        var scene = resolvedPipeline.parameters.scene_geometry_lens
        if let trackingCamera {
            scene.focal_length_millimeters = Float(trackingCamera.focalLengthMillimeters)
            scene.sensor_width_millimeters = Float(trackingCamera.gateWidthMillimeters)
            scene.sensor_height_millimeters = Float(trackingCamera.gateHeightMillimeters)
            scene.lens_shift = (0, 0)
            switch trackingCamera.distortion {
            case .pinhole:
                scene.lens_radial_distortion = (0, 0, 0)
            case let .de4RadialStandardDegree4(degree2, degree4):
                scene.lens_radial_distortion = (Float(degree2 * 0.5), Float(degree4 * 0.25), 0)
            }
            scene.lens_tangential_distortion = (0, 0)
        }
        return [intrinsicsKnot(scene)]
    }

    private static func poseKnot(
        timeNumerator: Int64,
        timeDenominator: UInt32,
        position: [Double],
        quaternion: [Double],
        interpolation: UInt32
    ) -> ScreenPhysicalPoseKnotV2 {
        var knot = ScreenPhysicalPoseKnotV2()
        knot.abi_version = SCREEN_PHYSICAL_FRAME_ABI_VERSION
        knot.time_numerator = timeNumerator
        knot.time_denominator = timeDenominator
        knot.position = (Float(position[0]), Float(position[1]), Float(position[2]))
        knot.rotation_xyzw = (
            Float(quaternion[0]), Float(quaternion[1]),
            Float(quaternion[2]), Float(quaternion[3])
        )
        knot.interpolation = interpolation
        return knot
    }

    private static func intrinsicsKnot(
        _ scene: ScreenSceneGeometryLensParametersV2
    ) -> ScreenPhysicalCameraIntrinsicsKnotV1 {
        var knot = ScreenPhysicalCameraIntrinsicsKnotV1()
        knot.abi_version = SCREEN_PHYSICAL_FRAME_ABI_VERSION
        knot.time_numerator = 0
        knot.time_denominator = 1
        knot.focal_length_millimeters = scene.focal_length_millimeters
        knot.sensor_width_millimeters = scene.sensor_width_millimeters
        knot.sensor_height_millimeters = scene.sensor_height_millimeters
        knot.lens_shift = scene.lens_shift
        knot.focus_distance_meters = scene.focus_distance_meters
        knot.f_stop = scene.f_stop
        knot.near_clip_meters = scene.near_clip_meters
        knot.far_clip_meters = scene.far_clip_meters
        knot.lens_radial_distortion = scene.lens_radial_distortion
        knot.lens_tangential_distortion = scene.lens_tangential_distortion
        knot.lens_longitudinal_chromatic_meters = scene.lens_longitudinal_chromatic_meters
        knot.lens_lateral_chromatic_scale = scene.lens_lateral_chromatic_scale
        knot.lens_vignetting_strength = scene.lens_vignetting_strength
        knot.lens_transmission_rgb = scene.lens_transmission_rgb
        knot.lens_center_softness_micrometers = scene.lens_center_softness_micrometers
        knot.lens_edge_softness_micrometers = scene.lens_edge_softness_micrometers
        knot.lens_veiling_glare_fraction = scene.lens_veiling_glare_fraction
        knot.interpolation = UInt32(SCREEN_PHYSICAL_POSE_HOLD.rawValue)
        return knot
    }

    private static func bridge(
        _ pointer: UnsafePointer<CChar>?,
        _ fallback: String
    ) -> PhysicalMetalFrameEngineError {
        .bridge(pointer.map(String.init(cString:)) ?? fallback)
    }
}
