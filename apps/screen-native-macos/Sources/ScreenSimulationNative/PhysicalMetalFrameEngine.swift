import Foundation
import Metal
import ScreenPhysicalBridge
import StudioColor

struct PhysicalMetalFrameSnapshot: @unchecked Sendable {
    let frame: StudioColorMetalFrame?
    let nativeDimensions: PhysicalDimensions
    let effectiveDimensions: PhysicalDimensions?
    let computedQuality: PhysicalQuality
    let returnedIntermediate: PhysicalIntermediate
    let state: PhysicalFrameState
    let progress: Double
    let diagnostics: [PhysicalStageDiagnostic]
    let parameterRevision: UInt64
    let parameterHash: PhysicalParameterHash
}

final class PhysicalMetalFrameJob: @unchecked Sendable {
    let cancellationIdentity: PhysicalFrameIdentity

    private let handle: ScreenPhysicalFrameJobRef
    private let timedInputs: ScreenPhysicalTimedInputSetV2Ref
    private let cameraPoseTrack: ScreenPhysicalCameraPoseTrackV2Ref
    private let screenPoseTrack: ScreenPhysicalScreenPoseTrackV2Ref
    private let sourceTexture: ScreenPhysicalTextureRef
    private let deviceSignalTexture: ScreenPhysicalTextureRef
    private let environmentTexture: ScreenPhysicalTextureRef?
    private let deviceProfile: ScreenDeviceProfileRef
    private let pipelineSnapshot: ScreenPhysicalPipelineSnapshotRef
    private let sourceFrame: StudioColorMetalFrame
    private let deviceSignalFrame: StudioColorMetalFrame
    private let environmentFrame: StudioColorMetalFrame?

    init(
        handle: ScreenPhysicalFrameJobRef,
        timedInputs: ScreenPhysicalTimedInputSetV2Ref,
        cameraPoseTrack: ScreenPhysicalCameraPoseTrackV2Ref,
        screenPoseTrack: ScreenPhysicalScreenPoseTrackV2Ref,
        sourceTexture: ScreenPhysicalTextureRef,
        deviceSignalTexture: ScreenPhysicalTextureRef,
        environmentTexture: ScreenPhysicalTextureRef?,
        deviceProfile: ScreenDeviceProfileRef,
        pipelineSnapshot: ScreenPhysicalPipelineSnapshotRef,
        sourceFrame: StudioColorMetalFrame,
        deviceSignalFrame: StudioColorMetalFrame,
        environmentFrame: StudioColorMetalFrame?,
        cancellationIdentity: PhysicalFrameIdentity
    ) {
        self.handle = handle
        self.timedInputs = timedInputs
        self.cameraPoseTrack = cameraPoseTrack
        self.screenPoseTrack = screenPoseTrack
        self.sourceTexture = sourceTexture
        self.deviceSignalTexture = deviceSignalTexture
        self.environmentTexture = environmentTexture
        self.deviceProfile = deviceProfile
        self.pipelineSnapshot = pipelineSnapshot
        self.sourceFrame = sourceFrame
        self.deviceSignalFrame = deviceSignalFrame
        self.environmentFrame = environmentFrame
        self.cancellationIdentity = cancellationIdentity
    }

    deinit {
        screen_physical_frame_job_release(handle)
        screen_physical_timed_input_set_v2_release(timedInputs)
        screen_physical_camera_pose_track_v2_release(cameraPoseTrack)
        screen_physical_screen_pose_track_v2_release(screenPoseTrack)
        screen_physical_texture_release(deviceSignalTexture)
        if let environmentTexture { screen_physical_texture_release(environmentTexture) }
        screen_physical_texture_release(sourceTexture)
        screen_device_profile_release(deviceProfile)
        screen_physical_pipeline_snapshot_release(pipelineSnapshot)
    }

    func cancel() -> Bool {
        screen_physical_frame_job_cancel(
            handle,
            ScreenPhysicalIdentity128(
                high: cancellationIdentity.high,
                low: cancellationIdentity.low
            )
        )
    }

    func snapshot() throws -> PhysicalMetalFrameSnapshot {
        var raw = ScreenPhysicalFrameResultV2()
        var error: UnsafePointer<CChar>?
        guard screen_physical_frame_job_snapshot(handle, &raw, &error) else {
            throw PhysicalMetalFrameEngineError.bridge(
                error.map(String.init(cString:)) ?? "No se ha podido leer el job físico."
            )
        }
        guard raw.abi_version == SCREEN_PHYSICAL_FRAME_ABI_VERSION,
              let quality = PhysicalQuality(rawValue: raw.computed_quality),
              let returnedIntermediate = PhysicalIntermediate(
                rawValue: raw.returned_intermediate
              ),
              let state = PhysicalFrameState(rawValue: raw.state)
        else {
            throw PhysicalMetalFrameEngineError.invalidSnapshot
        }
        let native = try PhysicalDimensions(
            width: Int(raw.native_width),
            height: Int(raw.native_height)
        )
        let effective = raw.effective_width == 0 || raw.effective_height == 0
            ? nil
            : try PhysicalDimensions(
                width: Int(raw.effective_width),
                height: Int(raw.effective_height)
            )
        let diagnostics = try decodeDiagnostics(raw)
        let hash = try withUnsafeBytes(of: raw.parameter_hash) {
            try PhysicalParameterHash(bytes: Array($0))
        }
        let frame: StudioColorMetalFrame?
        if let output = raw.output_texture,
           let pointer = screen_physical_texture_borrow_metal(output) {
            let object = Unmanaged<AnyObject>.fromOpaque(
                UnsafeMutableRawPointer(mutating: pointer)
            ).takeUnretainedValue()
            guard let texture = object as? MTLTexture else {
                throw PhysicalMetalFrameEngineError.invalidOutputTexture
            }
            frame = StudioColorMetalFrame(texture: texture)
        } else {
            frame = nil
        }
        return PhysicalMetalFrameSnapshot(
            frame: frame,
            nativeDimensions: native,
            effectiveDimensions: effective,
            computedQuality: quality,
            returnedIntermediate: returnedIntermediate,
            state: state,
            progress: Double(raw.progress),
            diagnostics: diagnostics,
            parameterRevision: raw.parameter_revision,
            parameterHash: hash
        )
    }

    private func decodeDiagnostics(
        _ result: ScreenPhysicalFrameResultV2
    ) throws -> [PhysicalStageDiagnostic] {
        guard result.stage_diagnostic_count == 0 || result.stage_diagnostics != nil else {
            throw PhysicalMetalFrameEngineError.invalidSnapshot
        }
        return try (0..<result.stage_diagnostic_count).map { index in
            let raw = result.stage_diagnostics![index]
            guard raw.abi_version == SCREEN_PHYSICAL_FRAME_ABI_VERSION,
                  let stage = PhysicalStageID(rawValue: raw.stage_id),
                  stage.domain.rawValue == raw.domain_id,
                  let state = PhysicalFrameState(rawValue: raw.state)
            else { throw PhysicalMetalFrameEngineError.invalidSnapshot }
            let message: String
            if raw.message.count == 0 {
                message = ""
            } else if let bytes = raw.message.bytes {
                message = String(
                    decoding: UnsafeBufferPointer(start: bytes, count: raw.message.count),
                    as: UTF8.self
                )
            } else {
                throw PhysicalMetalFrameEngineError.invalidSnapshot
            }
            return PhysicalStageDiagnostic(
                stage: stage,
                state: state,
                progress: Double(raw.progress),
                elapsedNanoseconds: raw.elapsed_nanoseconds,
                message: message
            )
        }
    }
}

@MainActor
final class PhysicalMetalFrameEngine {
    func submit(
        sourceACEScg: StudioColorMetalFrame,
        deviceSignal: StudioColorMetalFrame,
        environmentACEScg: StudioColorMetalFrame?,
        orchestration: PhysicalFrameOrchestration,
        resolvedDevice: ResolvedDevice,
        resolvedPipeline: PhysicalPipelineResolvedState,
        quality: PhysicalQuality,
        screenAmount: Double,
        contributions: [PhysicalStageContribution],
        requestedDimensions: PhysicalDimensions,
        cancellationIdentity: PhysicalFrameIdentity,
        progressIdentity: PhysicalFrameIdentity,
        parameterRevision: UInt64,
        parameterHash: PhysicalParameterHash,
        rasterPlacement: PhysicalRasterPlacement,
        requestedIntermediate: PhysicalIntermediate
    ) throws -> PhysicalMetalFrameJob {
        var error: UnsafePointer<CChar>?
        let sourcePointer = Unmanaged.passUnretained(sourceACEScg.texture as AnyObject).toOpaque()
        guard let sourceTexture = screen_physical_texture_create_borrowed_metal(
            sourcePointer,
            &error
        ) else { throw bridgeError(error, fallback: "No se ha creado la vista ACEScg.") }
        var deviceSignalTexture: ScreenPhysicalTextureRef?
        var environmentTexture: ScreenPhysicalTextureRef?
        var timedInputs: ScreenPhysicalTimedInputSetV2Ref?
        var cameraPoseTrack: ScreenPhysicalCameraPoseTrackV2Ref?
        var screenPoseTrack: ScreenPhysicalScreenPoseTrackV2Ref?
        var deviceProfile: ScreenDeviceProfileRef?
        var pipelineSnapshot: ScreenPhysicalPipelineSnapshotRef?
        var job: ScreenPhysicalFrameJobRef?
        defer {
            if job == nil {
                if let timedInputs {
                    screen_physical_timed_input_set_v2_release(timedInputs)
                }
                if let cameraPoseTrack {
                    screen_physical_camera_pose_track_v2_release(cameraPoseTrack)
                }
                if let screenPoseTrack {
                    screen_physical_screen_pose_track_v2_release(screenPoseTrack)
                }
                if let deviceSignalTexture {
                    screen_physical_texture_release(deviceSignalTexture)
                }
                if let environmentTexture {
                    screen_physical_texture_release(environmentTexture)
                }
                screen_physical_texture_release(sourceTexture)
                if let deviceProfile { screen_device_profile_release(deviceProfile) }
                if let pipelineSnapshot {
                    screen_physical_pipeline_snapshot_release(pipelineSnapshot)
                }
            }
        }
        let signalPointer = Unmanaged.passUnretained(deviceSignal.texture as AnyObject).toOpaque()
        deviceSignalTexture = screen_physical_texture_create_borrowed_metal(
            signalPointer,
            &error
        )
        guard let deviceSignalTexture else {
            throw bridgeError(error, fallback: "No se ha creado la vista Device RGB.")
        }
        if let environmentACEScg {
            let pointer = Unmanaged.passUnretained(
                environmentACEScg.texture as AnyObject
            ).toOpaque()
            environmentTexture = screen_physical_texture_create_borrowed_metal(
                pointer,
                &error
            )
            guard environmentTexture != nil else {
                throw bridgeError(error, fallback: "No se ha creado la vista del entorno ACEScg.")
            }
        }
        var timedSample = ScreenPhysicalTimedInputSampleV2()
        timedSample.abi_version = SCREEN_PHYSICAL_FRAME_ABI_VERSION
        timedSample.time_numerator = orchestration.frame.timeNumerator
        timedSample.time_denominator = orchestration.frame.timeDenominator
        timedSample.source_acescg = sourceTexture
        timedSample.device_signal = deviceSignalTexture
        timedInputs = screen_physical_timed_input_set_v2_create(
            &timedSample,
            1,
            rasterPlacement.rawValue,
            UInt32(SCREEN_PHYSICAL_SOURCE_SAMPLE_EXACT.rawValue),
            &error
        )
        guard let timedInputs else {
            throw bridgeError(error, fallback: "No se ha creado el input temporal físico.")
        }
        var cameraKnot = staticPoseKnot(
            frame: orchestration.frame,
            pose: orchestration.cameraPose
        )
        cameraPoseTrack = screen_physical_camera_pose_track_v2_create(
            &cameraKnot,
            1,
            &error
        )
        guard let cameraPoseTrack else {
            throw bridgeError(error, fallback: "No se ha creado el track constante de cámara.")
        }
        var screenKnot = staticPoseKnot(
            frame: orchestration.frame,
            pose: orchestration.screenPose
        )
        screenPoseTrack = screen_physical_screen_pose_track_v2_create(
            &screenKnot,
            1,
            &error
        )
        guard let screenPoseTrack else {
            throw bridgeError(error, fallback: "No se ha creado el track constante de pantalla.")
        }
        var deviceParameters = resolvedDevice.parameters
        deviceProfile = screen_device_profile_create(&deviceParameters, &error)
        guard let deviceProfile else {
            throw bridgeError(error, fallback: "No se ha resuelto el Device físico.")
        }
        var pipelineParameters = resolvedPipeline.parameters
        pipelineSnapshot = screen_physical_pipeline_snapshot_create(
            &pipelineParameters,
            &error
        )
        guard let pipelineSnapshot else {
            throw bridgeError(error, fallback: "No se ha resuelto el pipeline físico.")
        }
        let rawContributions = contributions.map(rawContribution)
        var raw = ScreenPhysicalFrameRequestV2()
        raw.abi_version = SCREEN_PHYSICAL_FRAME_ABI_VERSION
        raw.frame_index = orchestration.frame.frameIndex
        raw.timed_inputs = timedInputs
        raw.environment_acescg = environmentTexture
        raw.camera_pose_track = cameraPoseTrack
        raw.screen_pose_track = screenPoseTrack
        let shutter = orchestration.shutter
        raw.shutter_open_numerator = shutter.open.numerator
        raw.shutter_open_denominator = shutter.open.denominator
        raw.shutter_close_numerator = shutter.close.numerator
        raw.shutter_close_denominator = shutter.close.denominator
        raw.resolved_device = deviceProfile
        raw.resolved_pipeline = pipelineSnapshot
        raw.quality = quality.rawValue
        raw.screen_amount = Float(screenAmount)
        raw.requested_width = UInt32(requestedDimensions.width)
        raw.requested_height = UInt32(requestedDimensions.height)
        raw.requested_intermediate = requestedIntermediate.rawValue
        raw.cancellation_identity = ScreenPhysicalIdentity128(
            high: cancellationIdentity.high,
            low: cancellationIdentity.low
        )
        raw.progress_identity = ScreenPhysicalIdentity128(
            high: progressIdentity.high,
            low: progressIdentity.low
        )
        raw.parameter_revision = parameterRevision
        withUnsafeMutableBytes(of: &raw.parameter_hash) { destination in
            destination.copyBytes(from: parameterHash.bytes)
        }
        job = rawContributions.withUnsafeBufferPointer { values in
            raw.stage_contributions = values.baseAddress
            raw.stage_contribution_count = values.count
            return screen_physical_frame_submit(&raw, &error)
        }
        guard let job else {
            throw bridgeError(error, fallback: "El motor físico rechazó el frame.")
        }
        return PhysicalMetalFrameJob(
            handle: job,
            timedInputs: timedInputs,
            cameraPoseTrack: cameraPoseTrack,
            screenPoseTrack: screenPoseTrack,
            sourceTexture: sourceTexture,
            deviceSignalTexture: deviceSignalTexture,
            environmentTexture: environmentTexture,
            deviceProfile: deviceProfile,
            pipelineSnapshot: pipelineSnapshot,
            sourceFrame: sourceACEScg,
            deviceSignalFrame: deviceSignal,
            environmentFrame: environmentACEScg,
            cancellationIdentity: cancellationIdentity
        )
    }

    private func staticPoseKnot(
        frame: PhysicalFrameSelection,
        pose: PhysicalPoseSnapshot
    ) -> ScreenPhysicalPoseKnotV2 {
        var knot = ScreenPhysicalPoseKnotV2()
        knot.abi_version = SCREEN_PHYSICAL_FRAME_ABI_VERSION
        knot.time_numerator = frame.timeNumerator
        knot.time_denominator = frame.timeDenominator
        knot.position = (pose.position.x, pose.position.y, pose.position.z)
        knot.rotation_xyzw = (
            pose.rotation.x,
            pose.rotation.y,
            pose.rotation.z,
            pose.rotation.w
        )
        knot.interpolation = UInt32(SCREEN_PHYSICAL_POSE_HOLD.rawValue)
        return knot
    }

    private func rawContribution(
        _ contribution: PhysicalStageContribution
    ) -> ScreenPhysicalStageContributionV2 {
        var raw = ScreenPhysicalStageContributionV2()
        raw.abi_version = SCREEN_PHYSICAL_FRAME_ABI_VERSION
        raw.domain_id = contribution.stage.domain.rawValue
        raw.stage_id = contribution.stage.id
        switch contribution.control {
        case let .continuous(amount, limits):
            raw.control_semantics = UInt32(SCREEN_PHYSICAL_CONTROL_CONTINUOUS.rawValue)
            raw.amount = Float(amount)
            raw.visual_minimum = Float(limits.visualRange.lowerBound)
            raw.visual_maximum = Float(limits.visualRange.upperBound)
            raw.safe_maximum = Float(limits.safeRange.upperBound)
            raw.discrete_enabled = false
        case let .discrete(enabled):
            raw.control_semantics = UInt32(SCREEN_PHYSICAL_CONTROL_DISCRETE.rawValue)
            raw.amount = 0
            raw.visual_minimum = 0
            raw.visual_maximum = 2
            raw.safe_maximum = 4
            raw.discrete_enabled = enabled
        }
        raw.exact_identity_at_zero = contribution.exactIdentityAtZero
        return raw
    }

    private func bridgeError(
        _ error: UnsafePointer<CChar>?,
        fallback: String
    ) -> PhysicalMetalFrameEngineError {
        .bridge(error.map(String.init(cString:)) ?? fallback)
    }
}

enum PhysicalMetalFrameEngineError: Error, LocalizedError {
    case bridge(String)
    case invalidSnapshot
    case invalidOutputTexture

    var errorDescription: String? {
        switch self {
        case let .bridge(message): message
        case .invalidSnapshot: "El motor físico devolvió un snapshot ABI inválido."
        case .invalidOutputTexture: "El motor físico devolvió una textura Metal inválida."
        }
    }
}

private extension PhysicalStageID {
    init?(rawValue: UInt32) {
        if let section = ScreenPhysicalSection(rawValue: rawValue) {
            self = .screen(section)
        } else if let section = CapturePhysicalSection(rawValue: rawValue) {
            self = .capture(section)
        } else {
            return nil
        }
    }
}
