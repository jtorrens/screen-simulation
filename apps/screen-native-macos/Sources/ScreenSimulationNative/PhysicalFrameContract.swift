import Foundation
import ScreenPhysicalBridge

enum PhysicalQuality: UInt32, CaseIterable, Identifiable, Sendable {
    /// Host-only ideal framing route. It never crosses the physical ABI.
    case setup = 4
    case environmentSetup = 5
    case draft = 0
    case medium = 1
    case high = 2
    case native = 3

    var id: UInt32 { rawValue }
}

enum PhysicalDomainID: UInt32, CaseIterable, Identifiable, Sendable {
    case screen = 0x100
    case capture = 0x200

    var id: UInt32 { rawValue }
}

protocol PhysicalSectionID: CaseIterable, Identifiable, RawRepresentable, Sendable
where RawValue == UInt32, ID == UInt32 {}

enum ScreenPhysicalSection: UInt32, PhysicalSectionID {
    case emission = 0x101
    case subpixelGeometry = 0x102
    case panelUniformity = 0x108
    case panelLightSpread = 0x103
    case temporal = 0x104
    case coverGlass = 0x105
    case environment = 0x106
    case coverGlow = 0x107

    var id: UInt32 { rawValue }
}

enum CapturePhysicalSection: UInt32, PhysicalSectionID {
    case geometry = 0x201
    case lens = 0x202
    case exposureShutter = 0x203
    case sensorCFA = 0x204
    case noise = 0x205
    case developDemosaic = 0x206
    case sensorBloom = 0x207
    case computationalCapture = 0x208

    var id: UInt32 { rawValue }
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

    var domain: PhysicalDomainID {
        switch self {
        case .screen: .screen
        case .capture: .capture
        }
    }

    static let ordered: [Self] = [
        .screen(.emission),
        .screen(.subpixelGeometry),
        .screen(.panelUniformity),
        .screen(.panelLightSpread),
        .screen(.temporal),
        .capture(.geometry),
        .screen(.coverGlass),
        .screen(.environment),
        .screen(.coverGlow),
        .capture(.lens),
        .capture(.exposureShutter),
        .capture(.computationalCapture),
        .capture(.sensorBloom),
        .capture(.sensorCFA),
        .capture(.noise),
        .capture(.developDemosaic),
    ]

    /// Continuous stage amounts surfaced in General in pipeline order. These
    /// are the contract values themselves, not group masters or copied state.
    static let generalOverviewContinuous: [Self] = [
        .screen(.temporal),
        .screen(.coverGlass),
        .screen(.environment),
        .screen(.coverGlow),
        .capture(.lens),
        .capture(.exposureShutter),
        .capture(.computationalCapture),
        .capture(.sensorBloom),
        .capture(.noise),
    ]

    var contributionLimits: PhysicalContributionLimits {
        switch self {
        case .screen(.coverGlass):
            .init(visualRange: 0 ... 2, safeRange: 0 ... 2)
        case .capture(.computationalCapture):
            .init(visualRange: 0 ... 1.5, safeRange: 0 ... 1.5)
        default:
            .standard
        }
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

    init(frameIndex: Int64, timeNumerator: Int64, timeDenominator: UInt32) throws {
        guard frameIndex >= 0 else { throw PhysicalContractError.invalidFrameIndex }
        guard timeDenominator != 0 else { throw PhysicalContractError.invalidFrameTime }
        self.frameIndex = frameIndex
        self.timeNumerator = timeNumerator
        self.timeDenominator = timeDenominator
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
    case sensorBloom = 12
    case sensorNoise = 13
    case rawMosaic = 14
    case developedACEScg = 15
    case cameraRenderedACEScg = 16

    var id: UInt32 { rawValue }

    static let supportedDiagnostics: [Self] = [
        .sourceACEScg,
        .deviceSignal,
        .panelEmission,
        .subpixelRadiance,
        .panelUniformity,
        .panelLightSpread,
        .relativeGeometry,
        .coverEnvironment,
        .coverGlow,
        .lensProjection,
        .shutterMotion,
        .computationalCapture,
        .sensorBloom,
        .sensorNoise,
        .rawMosaic,
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
        case .relativeGeometry: "Relative Geometry"
        case .developedACEScg: "Developed"
        case .cameraRenderedACEScg: "Camera Rendering Intent"
        case .coverEnvironment: "Cover / Environment"
        case .coverGlow: "Cover Glow"
        case .lensProjection: "Lens / Projection"
        case .shutterMotion: "Shutter / Motion"
        case .computationalCapture: "Computational Capture"
        case .sensorBloom: "Sensor Bloom"
        case .sensorNoise: "Sensor / Noise"
        case .rawMosaic: "RAW Mosaic"
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

struct PhysicalScreenPoseTrack: @unchecked Sendable {
    let reference: ScreenPhysicalScreenPoseTrackV2Ref
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

struct ResolvedPhysicalPipelineSnapshot: @unchecked Sendable {
    let reference: ScreenPhysicalPipelineSnapshotRef
}

struct PhysicalFrameRequest: @unchecked Sendable {
    static let abiVersion = UInt32(SCREEN_PHYSICAL_FRAME_ABI_VERSION)

    let frame: PhysicalFrameSelection
    let timedInputs: PhysicalTimedInputSet
    let cameraPoseTrack: PhysicalCameraPoseTrack
    let screenPoseTrack: PhysicalScreenPoseTrack
    let shutterInterval: PhysicalShutterInterval
    let resolvedDevice: ResolvedDevice
    let resolvedPipeline: ResolvedPhysicalPipelineSnapshot
    let quality: PhysicalQuality
    let screenAmount: Double
    let stageContributions: [PhysicalStageContribution]
    let requestedDimensions: PhysicalDimensions
    let requestedIntermediate: PhysicalIntermediate
    let cancellationIdentity: PhysicalFrameIdentity
    let progressIdentity: PhysicalFrameIdentity
    let parameterRevision: UInt64
    let parameterHash: PhysicalParameterHash

    init(
        frame: PhysicalFrameSelection,
        timedInputs: PhysicalTimedInputSet,
        cameraPoseTrack: PhysicalCameraPoseTrack,
        screenPoseTrack: PhysicalScreenPoseTrack,
        shutterInterval: PhysicalShutterInterval,
        resolvedDevice: ResolvedDevice,
        resolvedPipeline: ResolvedPhysicalPipelineSnapshot,
        quality: PhysicalQuality,
        screenAmount: Double,
        stageContributions: [PhysicalStageContribution],
        requestedDimensions: PhysicalDimensions,
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
        self.cameraPoseTrack = cameraPoseTrack
        self.screenPoseTrack = screenPoseTrack
        self.shutterInterval = shutterInterval
        self.resolvedDevice = resolvedDevice
        self.resolvedPipeline = resolvedPipeline
        self.quality = quality
        self.screenAmount = screenAmount
        self.stageContributions = stageContributions
        self.requestedDimensions = requestedDimensions
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
    case invalidParameterHash
    case invalidStageOrder
}
