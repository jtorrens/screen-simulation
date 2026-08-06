import Foundation
import ScreenPhysicalBridge

enum PhysicalQuality: UInt32, CaseIterable, Identifiable, Sendable {
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
    case panelLightSpread = 0x103
    case temporal = 0x104
    case coverGlass = 0x105
    case environment = 0x106

    var id: UInt32 { rawValue }
}

enum CapturePhysicalSection: UInt32, PhysicalSectionID {
    case geometry = 0x201
    case lens = 0x202
    case exposureShutter = 0x203
    case sensorCFA = 0x204
    case noise = 0x205
    case developDemosaic = 0x206

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

    static let ordered: [Self] =
        ScreenPhysicalSection.allCases.map(Self.screen)
        + CapturePhysicalSection.allCases.map(Self.capture)

    var isImplementedByUnifiedPipeline: Bool {
        self == .screen(.emission)
            || self == .screen(.subpixelGeometry)
            || self == .screen(.panelLightSpread)
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
    case panelLightSpread = 4
    case coverEnvironment = 5
    case sceneGeometryLens = 6
    case shutterMotion = 7
    case sensorNoise = 8
    case rawMosaic = 9
    case developedACEScg = 10

    var id: UInt32 { rawValue }
}

struct PhysicalACEScgTexture: @unchecked Sendable {
    let reference: ScreenPhysicalTextureRef
}

struct PhysicalDeviceSignalTexture: @unchecked Sendable {
    let reference: ScreenPhysicalTextureRef
}

struct PhysicalFrameInput: @unchecked Sendable {
    let sourceACEScg: PhysicalACEScgTexture
    let deviceSignal: PhysicalDeviceSignalTexture
    let rasterPlacement: PhysicalRasterPlacement
}

struct ResolvedPhysicalPipelineSnapshot: @unchecked Sendable {
    let reference: ScreenPhysicalPipelineSnapshotRef
}

struct PhysicalFrameRequest: @unchecked Sendable {
    static let abiVersion = UInt32(SCREEN_PHYSICAL_FRAME_ABI_VERSION)

    let frame: PhysicalFrameSelection
    let input: PhysicalFrameInput
    let resolvedDevice: ResolvedDevice
    let resolvedPipeline: ResolvedPhysicalPipelineSnapshot
    let quality: PhysicalQuality
    let screenAmount: Double
    let captureAmount: Double
    let stageContributions: [PhysicalStageContribution]
    let requestedDimensions: PhysicalDimensions
    let requestedIntermediate: PhysicalIntermediate
    let cancellationIdentity: PhysicalFrameIdentity
    let progressIdentity: PhysicalFrameIdentity
    let parameterRevision: UInt64
    let parameterHash: PhysicalParameterHash

    init(
        frame: PhysicalFrameSelection,
        input: PhysicalFrameInput,
        resolvedDevice: ResolvedDevice,
        resolvedPipeline: ResolvedPhysicalPipelineSnapshot,
        quality: PhysicalQuality,
        screenAmount: Double,
        captureAmount: Double,
        stageContributions: [PhysicalStageContribution],
        requestedDimensions: PhysicalDimensions,
        requestedIntermediate: PhysicalIntermediate,
        cancellationIdentity: PhysicalFrameIdentity,
        progressIdentity: PhysicalFrameIdentity,
        parameterRevision: UInt64,
        parameterHash: PhysicalParameterHash
    ) throws {
        try PhysicalContributionLimits.standard.validate(screenAmount)
        try PhysicalContributionLimits.standard.validate(captureAmount)
        guard stageContributions.map(\.stage) == PhysicalStageID.ordered else {
            throw PhysicalContractError.invalidStageOrder
        }
        self.frame = frame
        self.input = input
        self.resolvedDevice = resolvedDevice
        self.resolvedPipeline = resolvedPipeline
        self.quality = quality
        self.screenAmount = screenAmount
        self.captureAmount = captureAmount
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
