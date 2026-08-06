import Foundation

@MainActor
final class PhysicalModelController: ObservableObject {
    struct StageValue: Equatable, Sendable {
        let stage: PhysicalStageID
        let exactIdentityAtZero: Bool
        var control: PhysicalControlSemantics
    }

    struct CompletedFrame: Equatable, Sendable {
        let nativeDimensions: PhysicalDimensions
        let effectiveDimensions: PhysicalDimensions
        let quality: PhysicalQuality
        let parameterRevision: UInt64
        let elapsedSeconds: Double
    }

    private struct IsolationSnapshot {
        let screenAmount: Double
        let stages: [PhysicalStageID: StageValue]
    }

    @Published private(set) var screenAmount = 1.0
    @Published private(set) var stages: [PhysicalStageID: StageValue]
    @Published private(set) var quality = PhysicalQuality.draft
    @Published private(set) var frameState = PhysicalFrameState.idle
    @Published private(set) var progress = 0.0
    @Published private(set) var parameterRevision: UInt64 = 0
    @Published private(set) var completedFrame: CompletedFrame?
    @Published private(set) var isolatedStage: PhysicalStageID?
    @Published private(set) var diagnostics: [PhysicalStageDiagnostic] = []
    @Published private(set) var computedQuality = PhysicalQuality.draft
    @Published private(set) var effectiveDimensions: PhysicalDimensions?
    @Published private(set) var lastInteractiveSeconds: Double?

    var interactiveInvalidation: (() -> Void)?
    var cancelNativeWork: (() -> Void)?

    private var isolationSnapshot: IsolationSnapshot?
    private var nativeStartedAt: ContinuousClock.Instant?

    init() {
        var values: [PhysicalStageID: StageValue] = [:]
        for stage in PhysicalStageID.ordered {
            let discrete = stage == .capture(.sensorCFA)
                || stage == .capture(.developDemosaic)
            values[stage] = StageValue(
                stage: stage,
                exactIdentityAtZero: !discrete,
                control: discrete
                    ? .discrete(enabled: true)
                    : .continuous(amount: 1, limits: stage.contributionLimits)
            )
        }
        stages = values
    }

    var orderedContributions: [PhysicalStageContribution] {
        PhysicalStageID.ordered.compactMap { stage in
            guard let value = stages[stage] else { return nil }
            return try? PhysicalStageContribution(
                stage: stage,
                control: value.control,
                exactIdentityAtZero: value.exactIdentityAtZero
            )
        }
    }

    var activeScreenStageCount: Int { activeCount(in: .screen) }
    var activeCaptureStageCount: Int { activeCount(in: .capture) }

    func stageValue(_ stage: PhysicalStageID) -> StageValue {
        precondition(stages[stage] != nil, "Unknown physical stage")
        return stages[stage]!
    }

    func setQuality(_ quality: PhysicalQuality) {
        guard self.quality != quality else { return }
        self.quality = quality
        invalidateParameters()
    }

    func setDomainAmount(_ amount: Double, domain: PhysicalDomainID) throws {
        try PhysicalContributionLimits.standard.validate(amount)
        switch domain {
        case .screen:
            guard screenAmount != amount else { return }
            screenAmount = amount
        case .capture:
            throw PhysicalModelStateError.domainHasNoContinuousMaster
        }
        invalidateParameters()
    }

    func setContinuousAmount(_ amount: Double, stage: PhysicalStageID) throws {
        if stage == .capture(.noise), amount > 0,
           stageValue(.capture(.sensorCFA)).control == .discrete(enabled: false)
        {
            throw PhysicalModelStateError.invalidStageCombination
        }
        guard var value = stages[stage],
              case let .continuous(_, limits) = value.control
        else { throw PhysicalModelStateError.stageIsNotContinuous }
        try limits.validate(amount)
        value.control = .continuous(amount: amount, limits: limits)
        guard stages[stage] != value else { return }
        stages[stage] = value
        invalidateParameters()
    }

    func setDiscreteEnabled(_ enabled: Bool, stage: PhysicalStageID) throws {
        if stage == .capture(.developDemosaic), enabled,
           stageValue(.capture(.sensorCFA)).control == .discrete(enabled: false)
        {
            throw PhysicalModelStateError.invalidStageCombination
        }
        guard var value = stages[stage], case .discrete = value.control else {
            throw PhysicalModelStateError.stageIsNotDiscrete
        }
        value.control = .discrete(enabled: enabled)
        guard stages[stage] != value else { return }
        stages[stage] = value
        if stage == .capture(.sensorCFA), !enabled {
            if var noise = stages[.capture(.noise)],
               case let .continuous(_, limits) = noise.control
            {
                noise.control = .continuous(amount: 0, limits: limits)
                stages[.capture(.noise)] = noise
            }
            if var develop = stages[.capture(.developDemosaic)] {
                develop.control = .discrete(enabled: false)
                stages[.capture(.developDemosaic)] = develop
            }
        }
        invalidateParameters()
    }

    func resetToPhysical(_ stage: PhysicalStageID) throws {
        guard let value = stages[stage] else {
            throw PhysicalModelStateError.unknownStage
        }
        switch value.control {
        case .continuous:
            try setContinuousAmount(1, stage: stage)
        case .discrete:
            try setDiscreteEnabled(true, stage: stage)
        }
    }

    func toggleIsolation(_ stage: PhysicalStageID) throws {
        if isolatedStage == stage {
            restoreIsolation()
            return
        }
        if isolatedStage != nil { restoreIsolation() }
        isolationSnapshot = IsolationSnapshot(
            screenAmount: screenAmount,
            stages: stages
        )
        isolatedStage = stage
        for candidate in PhysicalStageID.ordered where candidate != stage {
            guard var value = stages[candidate] else { continue }
            switch value.control {
            case let .continuous(_, limits):
                value.control = .continuous(amount: 0, limits: limits)
            case .discrete:
                value.control = .discrete(enabled: false)
            }
            stages[candidate] = value
        }
        if stage.domain == .screen, screenAmount == 0 { screenAmount = 1 }
        invalidateParameters()
    }

    func restoreIsolation() {
        guard let snapshot = isolationSnapshot else { return }
        screenAmount = snapshot.screenAmount
        stages = snapshot.stages
        isolationSnapshot = nil
        isolatedStage = nil
        invalidateParameters()
    }

    func beginNative() throws {
        guard frameState != .rendering else {
            throw PhysicalModelStateError.nativeAlreadyRendering
        }
        quality = .native
        frameState = .rendering
        progress = 0
        nativeStartedAt = .now
    }

    func updateNativeProgress(_ progress: Double) {
        guard frameState == .rendering else { return }
        self.progress = min(1, max(0, progress))
    }

    func publishInteractive(
        _ snapshot: PhysicalMetalFrameSnapshot,
        elapsedSeconds: Double
    ) {
        computedQuality = snapshot.computedQuality
        effectiveDimensions = snapshot.effectiveDimensions
        diagnostics = snapshot.diagnostics
        lastInteractiveSeconds = max(0, elapsedSeconds)
    }

    func publishNative(_ snapshot: PhysicalMetalFrameSnapshot) {
        computedQuality = snapshot.computedQuality
        effectiveDimensions = snapshot.effectiveDimensions
        diagnostics = snapshot.diagnostics
        updateNativeProgress(snapshot.progress)
    }

    func completeNative(
        nativeDimensions: PhysicalDimensions,
        effectiveDimensions: PhysicalDimensions
    ) {
        guard frameState == .rendering else { return }
        let elapsed = nativeStartedAt.map {
            Double($0.duration(to: .now).components.attoseconds) / 1e18
                + Double($0.duration(to: .now).components.seconds)
        } ?? 0
        completedFrame = CompletedFrame(
            nativeDimensions: nativeDimensions,
            effectiveDimensions: effectiveDimensions,
            quality: .native,
            parameterRevision: parameterRevision,
            elapsedSeconds: max(0, elapsed)
        )
        nativeStartedAt = nil
        progress = 1
        frameState = .complete
    }

    func cancelNative() {
        guard frameState == .rendering else { return }
        cancelNativeWork?()
        nativeStartedAt = nil
        progress = 0
        frameState = .cancelled
    }

    func failNative() {
        guard frameState == .rendering else { return }
        nativeStartedAt = nil
        progress = 0
        frameState = .failed
    }

    private func activeCount(in domain: PhysicalDomainID) -> Int {
        stages.values.filter { value in
            guard value.stage.domain == domain else { return false }
            return switch value.control {
            case let .continuous(amount, _): amount > 0
            case let .discrete(enabled): enabled
            }
        }.count
    }

    private func invalidateParameters() {
        parameterRevision &+= 1
        if frameState == .rendering {
            cancelNativeWork?()
            nativeStartedAt = nil
            progress = 0
            frameState = completedFrame == nil ? .cancelled : .stale
        } else if frameState == .complete {
            frameState = .stale
        }
        if quality != .native { interactiveInvalidation?() }
    }
}

enum PhysicalModelStateError: Error, Equatable {
    case unknownStage
    case stageIsNotContinuous
    case stageIsNotDiscrete
    case nativeAlreadyRendering
    case domainHasNoContinuousMaster
    case invalidStageCombination
}
