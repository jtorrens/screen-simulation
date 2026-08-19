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
    private let sceneResolver: RustSceneFrameResolver
    private let sourceTexture: ScreenPhysicalTextureRef
    private let deviceSignalTexture: ScreenPhysicalTextureRef
    private let environmentTexture: ScreenPhysicalTextureRef?
    private let sourceFrame: StudioColorMetalFrame
    private let deviceSignalFrame: StudioColorMetalFrame
    private let environmentFrame: EnvironmentRadianceFrame?

    init(
        handle: ScreenPhysicalFrameJobRef,
        timedInputs: ScreenPhysicalTimedInputSetV2Ref,
        sceneResolver: RustSceneFrameResolver,
        sourceTexture: ScreenPhysicalTextureRef,
        deviceSignalTexture: ScreenPhysicalTextureRef,
        environmentTexture: ScreenPhysicalTextureRef?,
        sourceFrame: StudioColorMetalFrame,
        deviceSignalFrame: StudioColorMetalFrame,
        environmentFrame: EnvironmentRadianceFrame?,
        cancellationIdentity: PhysicalFrameIdentity
    ) {
        self.handle = handle
        self.timedInputs = timedInputs
        self.sceneResolver = sceneResolver
        self.sourceTexture = sourceTexture
        self.deviceSignalTexture = deviceSignalTexture
        self.environmentTexture = environmentTexture
        self.sourceFrame = sourceFrame
        self.deviceSignalFrame = deviceSignalFrame
        self.environmentFrame = environmentFrame
        self.cancellationIdentity = cancellationIdentity
    }

    deinit {
        screen_physical_frame_job_release(handle)
        screen_physical_timed_input_set_v2_release(timedInputs)
        screen_physical_texture_release(deviceSignalTexture)
        screen_physical_texture_release(sourceTexture)
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
        environmentACEScg: EnvironmentRadianceFrame?,
        orchestration: PhysicalFrameOrchestration,
        sceneResolver: RustSceneFrameResolver,
        quality: PhysicalQuality,
        deviceVfxAlphaMode: String,
        screenAmount: Double,
        contributions: [PhysicalStageContribution],
        requestedDimensions: PhysicalDimensions,
        renderContext: PhysicalRenderContext,
        cancellationIdentity: PhysicalFrameIdentity,
        progressIdentity: PhysicalFrameIdentity,
        parameterRevision: UInt64,
        parameterHash: PhysicalParameterHash,
        rasterPlacement: PhysicalRasterPlacement,
        requestedIntermediate: PhysicalIntermediate,
        vfxTransparency: PhysicalVfxTransparencyRequest? = nil
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
        var job: ScreenPhysicalFrameJobRef?
        defer {
            if job == nil {
                if let timedInputs {
                    screen_physical_timed_input_set_v2_release(timedInputs)
                }
                if let deviceSignalTexture {
                    screen_physical_texture_release(deviceSignalTexture)
                }
                screen_physical_texture_release(sourceTexture)
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
            environmentTexture = environmentACEScg.physicalTexture
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
        let rawContributions = contributions.map(rawContribution)
        var raw = ScreenPhysicalFrameRequestV2()
        raw.abi_version = SCREEN_PHYSICAL_FRAME_ABI_VERSION
        raw.frame_index = orchestration.frame.frameIndex
        raw.timed_inputs = timedInputs
        raw.environment_acescg = environmentTexture
        raw.scene_resolver = sceneResolver.reference
        let shutter = orchestration.shutter
        raw.shutter_open_numerator = shutter.open.numerator
        raw.shutter_open_denominator = shutter.open.denominator
        raw.shutter_close_numerator = shutter.close.numerator
        raw.shutter_close_denominator = shutter.close.denominator
        raw.quality = quality.rawValue
        switch deviceVfxAlphaMode {
        case "ignore":
            raw.device_vfx_alpha_mode = SCREEN_DEVICE_VFX_ALPHA_IGNORE
        case "device-transparency":
            raw.device_vfx_alpha_mode = SCREEN_DEVICE_VFX_ALPHA_TRANSPARENCY
        default:
            throw PhysicalMetalFrameEngineError.invalidSnapshot
        }
        raw.screen_amount = Float(screenAmount)
        raw.requested_width = UInt32(requestedDimensions.width)
        raw.requested_height = UInt32(requestedDimensions.height)
        raw.render_full_width = UInt32(renderContext.fullDimensions.width)
        raw.render_full_height = UInt32(renderContext.fullDimensions.height)
        raw.render_window_x = renderContext.window.originX
        raw.render_window_y = renderContext.window.originY
        raw.render_window_width = renderContext.window.width
        raw.render_window_height = renderContext.window.height
        raw.render_scale_x_numerator = renderContext.scaleX.numerator
        raw.render_scale_x_denominator = renderContext.scaleX.denominator
        raw.render_scale_y_numerator = renderContext.scaleY.numerator
        raw.render_scale_y_denominator = renderContext.scaleY.denominator
        raw.pixel_aspect_numerator = renderContext.pixelAspect.numerator
        raw.pixel_aspect_denominator = renderContext.pixelAspect.denominator
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
            if let vfxTransparency {
                guard requestedIntermediate == .deviceVfxTransparency,
                      vfxTransparency.activeWidth > 0,
                      vfxTransparency.activeHeight > 0 else { return nil }
                var spec = ScreenPhysicalVfxTransparencySpecV1()
                spec.abi_version = SCREEN_PHYSICAL_FRAME_ABI_VERSION
                spec.active_width = UInt32(vfxTransparency.activeWidth)
                spec.active_height = UInt32(vfxTransparency.activeHeight)
                spec.bake_depth_of_field = vfxTransparency.bakeDepthOfField
                return screen_physical_vfx_transparency_submit(&raw, &spec, &error)
            }
            guard requestedIntermediate != .deviceVfxTransparency else { return nil }
            return screen_physical_frame_submit(&raw, &error)
        }
        guard let job else {
            throw bridgeError(error, fallback: "El motor físico rechazó el frame.")
        }
        return PhysicalMetalFrameJob(
            handle: job,
            timedInputs: timedInputs,
            sceneResolver: sceneResolver,
            sourceTexture: sourceTexture,
            deviceSignalTexture: deviceSignalTexture,
            environmentTexture: environmentTexture,
            sourceFrame: sourceACEScg,
            deviceSignalFrame: deviceSignal,
            environmentFrame: environmentACEScg,
            cancellationIdentity: cancellationIdentity
        )
    }

    private func rawContribution(
        _ contribution: PhysicalStageContribution
    ) -> ScreenPhysicalStageContributionV3 {
        var raw = ScreenPhysicalStageContributionV3()
        raw.abi_version = SCREEN_PHYSICAL_FRAME_ABI_VERSION
        raw.stage_id = contribution.stage.id
        switch contribution.control {
        case let .continuous(amount, _):
            raw.amount = Float(amount)
            raw.discrete_enabled = false
        case let .discrete(enabled):
            raw.amount = 0
            raw.discrete_enabled = enabled
        }
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
