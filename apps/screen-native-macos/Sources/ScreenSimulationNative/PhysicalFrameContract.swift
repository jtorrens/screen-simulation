import Foundation
import ScreenPhysicalBridge

enum PhysicalQuality: UInt32, CaseIterable, Identifiable, Sendable {
    /// Host-only ideal framing route. It never crosses the physical ABI.
    case setup = 4
    case environmentSetup = 5
    case focusSetup = 6
    case draft = 0
    case medium = 1
    case high = 2
    case native = 3

    var id: UInt32 { rawValue }
}

enum PhysicalDomainID: CaseIterable, Identifiable, Sendable {
    case screen
    case capture

    var id: UInt32 { rawValue }

    var rawValue: UInt32 {
        switch self {
        case .screen: UInt32(SCREEN_PHYSICAL_DOMAIN_SCREEN.rawValue)
        case .capture: UInt32(SCREEN_PHYSICAL_DOMAIN_CAPTURE.rawValue)
        }
    }

    init?(rawValue: UInt32) {
        switch rawValue {
        case UInt32(SCREEN_PHYSICAL_DOMAIN_SCREEN.rawValue): self = .screen
        case UInt32(SCREEN_PHYSICAL_DOMAIN_CAPTURE.rawValue): self = .capture
        default: return nil
        }
    }
}

protocol PhysicalSectionID: CaseIterable, Identifiable, RawRepresentable, Sendable
where RawValue == UInt32, ID == UInt32 {}

enum ScreenPhysicalSection: CaseIterable, PhysicalSectionID {
    case emission
    case subpixelGeometry
    case panelUniformity
    case panelLightSpread
    case temporal
    case coverGlass
    case environment
    case coverGlow

    var id: UInt32 { rawValue }

    var rawValue: UInt32 {
        switch self {
        case .emission: UInt32(SCREEN_PHYSICAL_STAGE_SCREEN_EMISSION.rawValue)
        case .subpixelGeometry: UInt32(SCREEN_PHYSICAL_STAGE_SCREEN_SUBPIXEL_GEOMETRY.rawValue)
        case .panelUniformity: UInt32(SCREEN_PHYSICAL_STAGE_SCREEN_UNIFORMITY.rawValue)
        case .panelLightSpread: UInt32(SCREEN_PHYSICAL_STAGE_SCREEN_LIGHT_SPREAD.rawValue)
        case .temporal: UInt32(SCREEN_PHYSICAL_STAGE_SCREEN_TEMPORAL.rawValue)
        case .coverGlass: UInt32(SCREEN_PHYSICAL_STAGE_SCREEN_COVER_GLASS.rawValue)
        case .environment: UInt32(SCREEN_PHYSICAL_STAGE_SCREEN_ENVIRONMENT.rawValue)
        case .coverGlow: UInt32(SCREEN_PHYSICAL_STAGE_SCREEN_COVER_GLOW.rawValue)
        }
    }

    init?(rawValue: UInt32) {
        guard let value = Self.allCases.first(where: { $0.rawValue == rawValue }) else {
            return nil
        }
        self = value
    }
}

enum CapturePhysicalSection: CaseIterable, PhysicalSectionID {
    case geometry
    case lens
    case exposureShutter
    case sensorCollection
    case sensorReadout
    case developDemosaic
    case sensorBloom
    case computationalCapture

    var id: UInt32 { rawValue }

    var rawValue: UInt32 {
        switch self {
        case .geometry: UInt32(SCREEN_PHYSICAL_STAGE_CAPTURE_GEOMETRY.rawValue)
        case .lens: UInt32(SCREEN_PHYSICAL_STAGE_CAPTURE_LENS.rawValue)
        case .exposureShutter: UInt32(SCREEN_PHYSICAL_STAGE_CAPTURE_EXPOSURE_SHUTTER.rawValue)
        case .sensorCollection: UInt32(SCREEN_PHYSICAL_STAGE_CAPTURE_SENSOR_COLLECTION.rawValue)
        case .sensorReadout: UInt32(SCREEN_PHYSICAL_STAGE_CAPTURE_SENSOR_READOUT.rawValue)
        case .developDemosaic: UInt32(SCREEN_PHYSICAL_STAGE_CAPTURE_DEVELOP_DEMOSAIC.rawValue)
        case .sensorBloom: UInt32(SCREEN_PHYSICAL_STAGE_CAPTURE_SENSOR_BLOOM.rawValue)
        case .computationalCapture:
            UInt32(SCREEN_PHYSICAL_STAGE_CAPTURE_COMPUTATIONAL_CAPTURE.rawValue)
        }
    }

    init?(rawValue: UInt32) {
        guard let value = Self.allCases.first(where: { $0.rawValue == rawValue }) else {
            return nil
        }
        self = value
    }
}

enum PhysicalStageID: Hashable, Identifiable, Sendable {
    case screen(ScreenPhysicalSection)
    case capture(CapturePhysicalSection)

    var id: UInt32 {
        switch self {
        case let .screen(section): section.rawValue
        case let .capture(section): section.rawValue
        }
    }

    init?(rawValue: UInt32) {
        if let section = ScreenPhysicalSection(rawValue: rawValue) {
            self = .screen(section)
        } else if let section = CapturePhysicalSection(rawValue: rawValue) {
            self = .capture(section)
        } else {
            return nil
        }
    }

    var domain: PhysicalDomainID {
        PhysicalStageCatalog.descriptor(for: self).domain
    }

    static var ordered: [Self] { PhysicalStageCatalog.descriptors.map(\.stage) }

    /// Continuous stage amounts surfaced in General in pipeline order. These
    /// are the contract values themselves, not group masters or copied state.
    static var generalOverviewContinuous: [Self] {
        PhysicalStageCatalog.descriptors.filter(\.generalOverview).map(\.stage)
    }

    var contributionLimits: PhysicalContributionLimits {
        PhysicalStageCatalog.descriptor(for: self).limits
    }
}

struct PhysicalStageDescriptor: Sendable {
    let stage: PhysicalStageID
    let domain: PhysicalDomainID
    let continuous: Bool
    let limits: PhysicalContributionLimits
    let exactIdentityAtZero: Bool
    let generalOverview: Bool
}

enum PhysicalStageCatalog {
    static let descriptors: [PhysicalStageDescriptor] = {
        let count = screen_physical_stage_descriptor_count()
        precondition(count > 0, "Application published no physical stages")
        var resolved: [PhysicalStageDescriptor] = []
        resolved.reserveCapacity(count)
        for index in 0..<count {
            var raw = ScreenPhysicalStageDescriptorV1()
            precondition(
                screen_physical_stage_descriptor(index, &raw),
                "Application omitted physical stage descriptor \(index)"
            )
            precondition(raw.abi_version == SCREEN_PHYSICAL_FRAME_ABI_VERSION)
            guard let stage = PhysicalStageID(rawValue: raw.stage_id),
                  let domain = PhysicalDomainID(rawValue: raw.domain_id)
            else { preconditionFailure("Application published an unknown physical stage") }
            let continuous: Bool
            switch raw.control_semantics {
            case UInt32(SCREEN_PHYSICAL_CONTROL_CONTINUOUS.rawValue): continuous = true
            case UInt32(SCREEN_PHYSICAL_CONTROL_DISCRETE.rawValue): continuous = false
            default: preconditionFailure("Application published unknown control semantics")
            }
            let limits = PhysicalContributionLimits(
                visualRange: Double(raw.visual_minimum) ... Double(raw.visual_maximum),
                safeRange: Double(raw.visual_minimum) ... Double(raw.safe_maximum)
            )
            precondition(!continuous || (
                limits.visualRange.lowerBound.isFinite
                    && limits.visualRange.upperBound.isFinite
                    && limits.safeRange.upperBound.isFinite
                    && limits.visualRange.lowerBound <= limits.visualRange.upperBound
                    && limits.visualRange.upperBound <= limits.safeRange.upperBound
            ))
            resolved.append(.init(
                stage: stage,
                domain: domain,
                continuous: continuous,
                limits: limits,
                exactIdentityAtZero: raw.exact_identity_at_zero,
                generalOverview: raw.general_overview
            ))
        }
        precondition(Set(resolved.map(\.stage)).count == resolved.count)
        return resolved
    }()

    static func descriptor(for stage: PhysicalStageID) -> PhysicalStageDescriptor {
        guard let descriptor = descriptors.first(where: { $0.stage == stage }) else {
            preconditionFailure("Unknown physical stage")
        }
        return descriptor
    }
}

struct PhysicalContributionLimits: Equatable, Sendable {
    let visualRange: ClosedRange<Double>
    let safeRange: ClosedRange<Double>

    static let standard = Self(visualRange: 0 ... 2, safeRange: 0 ... 4)

    func validate(_ amount: Double) throws {
        guard amount.isFinite, safeRange.contains(amount) else {
            throw PhysicalContractError.amountOutsideSafeRange(amount, safeRange)
        }
    }
}

enum PhysicalControlSemantics: Equatable, Sendable {
    case continuous(amount: Double, limits: PhysicalContributionLimits)
    case discrete(enabled: Bool)
}

struct PhysicalStageContribution: Equatable, Identifiable, Sendable {
    let stage: PhysicalStageID
    var control: PhysicalControlSemantics
    let exactIdentityAtZero: Bool

    var id: UInt32 { stage.id }

    init(
        stage: PhysicalStageID,
        control: PhysicalControlSemantics,
        exactIdentityAtZero: Bool
    ) throws {
        if case let .continuous(amount, limits) = control {
            try limits.validate(amount)
        }
        self.stage = stage
        self.control = control
        self.exactIdentityAtZero = exactIdentityAtZero
    }

    var amount: Double? {
        guard case let .continuous(amount, _) = control else { return nil }
        return amount
    }
}

struct PhysicalFrameIdentity: Hashable, Sendable {
    let high: UInt64
    let low: UInt64
}

struct PhysicalFrameSelection: Equatable, Sendable {
    let frameIndex: Int64
    let timeNumerator: Int64
    let timeDenominator: UInt32
    let frameRateNumerator: UInt32
    let frameRateDenominator: UInt32

    init(
        frameIndex: Int64,
        timeNumerator: Int64,
        timeDenominator: UInt32,
        frameRateNumerator: UInt32,
        frameRateDenominator: UInt32
    ) throws {
        guard frameIndex >= 0 else { throw PhysicalContractError.invalidFrameIndex }
        guard timeDenominator != 0, frameRateNumerator != 0, frameRateDenominator != 0 else {
            throw PhysicalContractError.invalidFrameTime
        }
        self.frameIndex = frameIndex
        self.timeNumerator = timeNumerator
        self.timeDenominator = timeDenominator
        self.frameRateNumerator = frameRateNumerator
        self.frameRateDenominator = frameRateDenominator
    }
}

struct PhysicalDimensions: Equatable, Sendable {
    let width: Int
    let height: Int

    init(width: Int, height: Int) throws {
        guard width > 0, height > 0,
              width <= Int(UInt32.max), height <= Int(UInt32.max)
        else { throw PhysicalContractError.invalidDimensions }
        self.width = width
        self.height = height
    }
}

/// The largest centered square-pixel recording window with the authored gate aspect.
/// This is a sensor crop: no source or sensor image is stretched to obtain it.
struct PhysicalActiveSensorWindow: Equatable, Sendable {
    let originX: Int
    let originY: Int
    let width: Int
    let height: Int

    init(
        fullWidth: Int,
        fullHeight: Int,
        originX: Int,
        originY: Int,
        width: Int,
        height: Int
    ) throws {
        guard fullWidth > 0, fullHeight > 0,
              originX >= 0, originY >= 0, width > 0, height > 0,
              originX + width <= fullWidth, originY + height <= fullHeight
        else { throw PhysicalContractError.invalidDimensions }
        self.originX = originX
        self.originY = originY
        self.width = width
        self.height = height
    }

    init(
        fullWidth: Int,
        fullHeight: Int,
        gateWidth: Double,
        gateHeight: Double
    ) throws {
        guard fullWidth > 0, fullHeight > 0,
              gateWidth.isFinite, gateHeight.isFinite,
              gateWidth > 0, gateHeight > 0
        else { throw PhysicalContractError.invalidDimensions }
        let gateAspect = gateWidth / gateHeight
        let fullAspect = Double(fullWidth) / Double(fullHeight)
        if gateAspect >= fullAspect {
            width = fullWidth
            height = min(fullHeight, max(1, Int((Double(fullWidth) / gateAspect).rounded(.down))))
        } else {
            height = fullHeight
            width = min(fullWidth, max(1, Int((Double(fullHeight) * gateAspect).rounded(.down))))
        }
        originX = (fullWidth - width) / 2
        originY = (fullHeight - height) / 2
    }
}

struct PhysicalExactPositiveRatio: Equatable, Sendable {
    static let one = PhysicalExactPositiveRatio(uncheckedNumerator: 1, denominator: 1)

    let numerator: UInt32
    let denominator: UInt32

    init(numerator: UInt32, denominator: UInt32) throws {
        guard numerator > 0, denominator > 0 else {
            throw PhysicalContractError.invalidRenderContext
        }
        self.numerator = numerator
        self.denominator = denominator
    }

    private init(uncheckedNumerator numerator: UInt32, denominator: UInt32) {
        self.numerator = numerator
        self.denominator = denominator
    }
}

struct PhysicalRenderWindow: Equatable, Sendable {
    let originX: UInt32
    let originY: UInt32
    let width: UInt32
    let height: UInt32
}

struct PhysicalRenderContext: Equatable, Sendable {
    let fullDimensions: PhysicalDimensions
    let window: PhysicalRenderWindow
    let scaleX: PhysicalExactPositiveRatio
    let scaleY: PhysicalExactPositiveRatio
    let pixelAspect: PhysicalExactPositiveRatio

    static func fullFrame(_ dimensions: PhysicalDimensions) -> Self {
        Self(
            fullDimensions: dimensions,
            window: PhysicalRenderWindow(
                originX: 0,
                originY: 0,
                width: UInt32(dimensions.width),
                height: UInt32(dimensions.height)
            ),
            scaleX: .one,
            scaleY: .one,
            pixelAspect: .one
        )
    }
}

struct PhysicalParameterHash: Equatable, Sendable {
    static let byteCount = Int(SCREEN_PHYSICAL_PARAMETER_HASH_SIZE)
    let bytes: [UInt8]

    init(bytes: [UInt8]) throws {
        guard bytes.count == Self.byteCount else {
            throw PhysicalContractError.invalidParameterHash
        }
        self.bytes = bytes
    }
}

enum PhysicalRasterPlacement: UInt32, CaseIterable, Identifiable, Sendable {
    case fit = 0
    case fillCrop = 1
    case stretch = 2
    case oneToOne = 3

    var id: UInt32 { rawValue }
}

enum PhysicalIntermediate: UInt32, CaseIterable, Identifiable, Sendable {
    case sourceACEScg = 0
    case deviceSignal = 1
    case panelEmission = 2
    case subpixelRadiance = 3
    case panelUniformity = 4
    case panelLightSpread = 5
    case relativeGeometry = 6
    case coverEnvironment = 7
    case coverGlow = 8
    case lensProjection = 9
    case shutterMotion = 10
    case computationalCapture = 11
    case sensorCollection = 12
    case sensorBloom = 13
    case sensorReadoutRaw = 14
    case developedACEScg = 15
    case cameraRenderedACEScg = 16
    case panelTemporal = 17
    case deviceVfxTransparency = 18

    var id: UInt32 { rawValue }

    /// The raster whose sampling lattice owns evaluation of this checkpoint.
    /// Capture checkpoints must never inherit the Device aspect ratio: their
    /// pixels are camera photosites (or values developed from those photosites).
    var usesCaptureRaster: Bool {
        switch self {
        case .sensorCollection, .sensorBloom, .sensorReadoutRaw,
             .developedACEScg, .cameraRenderedACEScg:
            true
        case .sourceACEScg, .deviceSignal, .panelEmission, .subpixelRadiance,
             .panelUniformity, .panelLightSpread, .relativeGeometry,
             .coverEnvironment, .coverGlow, .lensProjection, .shutterMotion,
             .computationalCapture, .panelTemporal, .deviceVfxTransparency:
            false
        }
    }

    func nativeRasterSize(
        deviceWidth: Int,
        deviceHeight: Int,
        captureWidth: Int,
        captureHeight: Int
    ) -> (width: Int, height: Int) {
        usesCaptureRaster
            ? (captureWidth, captureHeight)
            : (deviceWidth, deviceHeight)
    }

    static let supportedDiagnostics: [Self] = [
        .sourceACEScg,
        .deviceSignal,
        .panelEmission,
        .subpixelRadiance,
        .panelUniformity,
        .panelLightSpread,
        .panelTemporal,
        .relativeGeometry,
        .coverEnvironment,
        .coverGlow,
        .lensProjection,
        .shutterMotion,
        .computationalCapture,
        .sensorCollection,
        .sensorBloom,
        .sensorReadoutRaw,
        .developedACEScg,
        .cameraRenderedACEScg,
    ]

    var uiLabel: String {
        switch self {
        case .sourceACEScg: "Source"
        case .deviceSignal: "Device"
        case .panelEmission: "Emission"
        case .subpixelRadiance: "Subpixel"
        case .panelUniformity: "Uniformity"
        case .panelLightSpread: "Spread"
        case .panelTemporal: "Panel Temporal"
        case .relativeGeometry: "Relative Geometry"
        case .developedACEScg: "Developed"
        case .cameraRenderedACEScg: "Camera Rendering Intent"
        case .deviceVfxTransparency: "Device VFX Transparency"
        case .coverEnvironment: "Cover / Environment"
        case .coverGlow: "Cover Glow"
        case .lensProjection: "Lens / Projection"
        case .shutterMotion: "Shutter / Motion"
        case .computationalCapture: "Computational Capture"
        case .sensorCollection: "Photosite / CFA Collection"
        case .sensorBloom: "Sensor Bloom"
        case .sensorReadoutRaw: "Sensor Readout / RAW"
        }
    }
}

struct PhysicalACEScgTexture: @unchecked Sendable {
    let reference: ScreenPhysicalTextureRef
}

struct PhysicalDeviceSignalTexture: @unchecked Sendable {
    let reference: ScreenPhysicalTextureRef
}

struct PhysicalTimedInputSet: @unchecked Sendable {
    let reference: ScreenPhysicalTimedInputSetV2Ref
}

struct PhysicalCameraPoseTrack: @unchecked Sendable {
    let reference: ScreenPhysicalCameraPoseTrackV2Ref
}

struct PhysicalCameraIntrinsicsTrack: @unchecked Sendable {
    let reference: ScreenPhysicalCameraIntrinsicsTrackV1Ref
}

struct PhysicalScreenPoseTrack: @unchecked Sendable {
    let reference: ScreenPhysicalScreenPoseTrackV2Ref
}

struct PhysicalSceneFrameResolver: @unchecked Sendable {
    let reference: ScreenSceneFrameResolverV1Ref
}

struct PhysicalRationalTime: Equatable, Sendable {
    let numerator: Int64
    let denominator: UInt32

    init(numerator: Int64, denominator: UInt32) throws {
        guard denominator != 0 else { throw PhysicalContractError.invalidFrameTime }
        self.numerator = numerator
        self.denominator = denominator
    }
}

struct PhysicalShutterInterval: Equatable, Sendable {
    let open: PhysicalRationalTime
    let close: PhysicalRationalTime
}

struct PhysicalVfxTransparencyRequest: Equatable, Sendable {
    let activeWidth: Int
    let activeHeight: Int
    let bakeDepthOfField: Bool
}

struct ResolvedPhysicalPipelineSnapshot: @unchecked Sendable {
    let reference: ScreenPhysicalPipelineSnapshotRef
}

struct PhysicalFrameRequest: @unchecked Sendable {
    static let abiVersion = UInt32(SCREEN_PHYSICAL_FRAME_ABI_VERSION)

    let frame: PhysicalFrameSelection
    let timedInputs: PhysicalTimedInputSet
    let sceneResolver: PhysicalSceneFrameResolver
    let shutterInterval: PhysicalShutterInterval
    let quality: PhysicalQuality
    let screenAmount: Double
    let stageContributions: [PhysicalStageContribution]
    let requestedDimensions: PhysicalDimensions
    let renderContext: PhysicalRenderContext
    let requestedIntermediate: PhysicalIntermediate
    let cancellationIdentity: PhysicalFrameIdentity
    let progressIdentity: PhysicalFrameIdentity
    let parameterRevision: UInt64
    let parameterHash: PhysicalParameterHash

    init(
        frame: PhysicalFrameSelection,
        timedInputs: PhysicalTimedInputSet,
        sceneResolver: PhysicalSceneFrameResolver,
        shutterInterval: PhysicalShutterInterval,
        quality: PhysicalQuality,
        screenAmount: Double,
        stageContributions: [PhysicalStageContribution],
        requestedDimensions: PhysicalDimensions,
        renderContext: PhysicalRenderContext,
        requestedIntermediate: PhysicalIntermediate,
        cancellationIdentity: PhysicalFrameIdentity,
        progressIdentity: PhysicalFrameIdentity,
        parameterRevision: UInt64,
        parameterHash: PhysicalParameterHash
    ) throws {
        try PhysicalContributionLimits.standard.validate(screenAmount)
        guard stageContributions.map(\.stage) == PhysicalStageID.ordered else {
            throw PhysicalContractError.invalidStageOrder
        }
        self.frame = frame
        self.timedInputs = timedInputs
        self.sceneResolver = sceneResolver
        self.shutterInterval = shutterInterval
        self.quality = quality
        self.screenAmount = screenAmount
        self.stageContributions = stageContributions
        self.requestedDimensions = requestedDimensions
        self.renderContext = renderContext
        self.requestedIntermediate = requestedIntermediate
        self.cancellationIdentity = cancellationIdentity
        self.progressIdentity = progressIdentity
        self.parameterRevision = parameterRevision
        self.parameterHash = parameterHash
    }
}

enum PhysicalFrameState: UInt32, CaseIterable, Sendable {
    case idle = 0
    case stale = 1
    case rendering = 2
    case cancelled = 3
    case failed = 4
    case complete = 5

    func canTransition(to destination: Self) -> Bool {
        if self == destination { return true }
        return switch (self, destination) {
        case (.idle, .rendering), (.stale, .rendering),
             (.rendering, .stale), (.rendering, .cancelled),
             (.rendering, .failed), (.rendering, .complete),
             (.complete, .stale), (.complete, .rendering),
             (.cancelled, .idle), (.cancelled, .rendering),
             (.failed, .idle), (.failed, .rendering):
            true
        default:
            false
        }
    }
}

struct PhysicalStageDiagnostic: Equatable, Sendable {
    let stage: PhysicalStageID
    let state: PhysicalFrameState
    let progress: Double
    let elapsedNanoseconds: UInt64
    let message: String
}

struct PhysicalFrameResult: @unchecked Sendable {
    let outputTexture: ScreenPhysicalTextureRef
    let returnedIntermediate: PhysicalIntermediate
    let nativeDimensions: PhysicalDimensions
    let effectiveDimensions: PhysicalDimensions
    let computedQuality: PhysicalQuality
    let state: PhysicalFrameState
    let progress: Double
    let diagnostics: [PhysicalStageDiagnostic]
    let parameterRevision: UInt64
    let parameterHash: PhysicalParameterHash
}

enum PhysicalContractError: Error, Equatable {
    case amountOutsideSafeRange(Double, ClosedRange<Double>)
    case invalidFrameIndex
    case invalidFrameTime
    case invalidDimensions
    case invalidRenderContext
    case invalidParameterHash
    case invalidStageOrder
}
