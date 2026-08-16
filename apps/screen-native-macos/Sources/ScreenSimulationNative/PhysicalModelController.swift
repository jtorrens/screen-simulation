import Foundation

struct PhysicalModelAuthoringState: Codable, Equatable, Sendable {
    struct ContinuousValue: Codable, Equatable, Sendable {
        var storedAmount: Double
        var isBypassed: Bool
    }

    enum StageControl: Codable, Equatable, Sendable {
        case continuous(ContinuousValue)
        case discrete(enabled: Bool)
    }

    struct Stage: Codable, Equatable, Sendable {
        let stableID: UInt32
        var control: StageControl
    }

    var screen: ContinuousValue
    var stages: [Stage]
}

@MainActor
final class PhysicalModelController: ObservableObject {
    struct StageValue: Equatable, Sendable {
        let stage: PhysicalStageID
        let exactIdentityAtZero: Bool
        var control: PhysicalControlSemantics
        var isBypassed: Bool
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
        let screenIsBypassed: Bool
        let stages: [PhysicalStageID: StageValue]
    }

    @Published private(set) var screenAmount = 1.0
    @Published private(set) var screenIsBypassed = false
    @Published private(set) var stages: [PhysicalStageID: StageValue]
    @Published private(set) var quality = PhysicalQuality.setup
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
        for descriptor in PhysicalStageCatalog.descriptors {
            values[descriptor.stage] = StageValue(
                stage: descriptor.stage,
                exactIdentityAtZero: descriptor.exactIdentityAtZero,
                control: descriptor.continuous
                    ? .continuous(amount: 1, limits: descriptor.limits)
                    : .discrete(enabled: true),
                isBypassed: false
            )
        }
        stages = values
    }

    var orderedContributions: [PhysicalStageContribution] {
        PhysicalStageID.ordered.compactMap { stage in
            guard let value = stages[stage] else { return nil }
            let effectiveControl: PhysicalControlSemantics
            if value.isBypassed, case let .continuous(_, limits) = value.control {
                effectiveControl = .continuous(amount: 0, limits: limits)
            } else {
                effectiveControl = value.control
            }
            return try? PhysicalStageContribution(
                stage: stage,
                control: effectiveControl,
                exactIdentityAtZero: value.exactIdentityAtZero
            )
        }
    }

    var effectiveScreenAmount: Double { screenIsBypassed ? 0 : screenAmount }

    var authoringState: PhysicalModelAuthoringState {
        PhysicalModelAuthoringState(
            screen: .init(storedAmount: screenAmount, isBypassed: screenIsBypassed),
            stages: PhysicalStageID.ordered.compactMap { stage in
                guard let value = stages[stage] else { return nil }
                let control: PhysicalModelAuthoringState.StageControl = switch value.control {
                case let .continuous(amount, _):
                    .continuous(.init(storedAmount: amount, isBypassed: value.isBypassed))
                case let .discrete(enabled):
                    .discrete(enabled: enabled)
                }
                return .init(stableID: stage.id, control: control)
            }
        )
    }

    var activeScreenStageCount: Int { activeCount(in: .screen) }
    var activeCaptureStageCount: Int { activeCount(in: .capture) }

    func stageValue(_ stage: PhysicalStageID) -> StageValue {
        precondition(stages[stage] != nil, "Unknown physical stage")
        return stages[stage]!
    }

    func bypassDiagnosticMessage(for stage: PhysicalStageID) -> String? {
        guard let value = stages[stage] else { return nil }
        let domainBypassed = stage.domain == .screen && screenIsBypassed
        guard value.isBypassed || domainBypassed else { return nil }
        guard case let .continuous(stored, _) = value.control else { return nil }
        return "BYPASSED · effective 0 · stored \(stored.formatted(.number.precision(.fractionLength(2))))"
    }

    func setQuality(_ quality: PhysicalQuality) {
        guard self.quality != quality else { return }
        self.quality = quality
        invalidateParameters(returnToSetup: false)
    }

    func invalidateExternalParameters() {
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

    func setDomainBypassed(_ bypassed: Bool, domain: PhysicalDomainID) throws {
        guard domain == .screen else {
            throw PhysicalModelStateError.domainHasNoContinuousMaster
        }
        guard screenIsBypassed != bypassed else { return }
        screenIsBypassed = bypassed
        invalidateParameters()
    }

    func setContinuousAmount(_ amount: Double, stage: PhysicalStageID) throws {
        if stage == .capture(.sensorCollection), amount > 0,
           stageValue(.capture(.sensorReadout)).control == .discrete(enabled: false)
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

    func setContinuousBypassed(_ bypassed: Bool, stage: PhysicalStageID) throws {
        guard var value = stages[stage], case .continuous = value.control else {
            throw PhysicalModelStateError.stageIsNotContinuous
        }
        guard value.isBypassed != bypassed else { return }
        value.isBypassed = bypassed
        stages[stage] = value
        invalidateParameters()
    }

    func restoreAuthoringState(_ state: PhysicalModelAuthoringState) throws {
        try PhysicalContributionLimits.standard.validate(state.screen.storedAmount)
        guard state.stages.map(\.stableID) == PhysicalStageID.ordered.map(\.id) else {
            throw PhysicalModelStateError.invalidAuthoringState
        }
        var restored: [PhysicalStageID: StageValue] = [:]
        for (stage, authored) in zip(PhysicalStageID.ordered, state.stages) {
            let descriptor = PhysicalStageCatalog.descriptor(for: stage)
            let control: PhysicalControlSemantics
            let bypassed: Bool
            switch authored.control {
            case let .continuous(value):
                guard descriptor.continuous else {
                    throw PhysicalModelStateError.invalidAuthoringState
                }
                try descriptor.limits.validate(value.storedAmount)
                control = .continuous(
                    amount: value.storedAmount,
                    limits: descriptor.limits
                )
                bypassed = value.isBypassed
            case let .discrete(enabled):
                guard !descriptor.continuous else {
                    throw PhysicalModelStateError.invalidAuthoringState
                }
                control = .discrete(enabled: enabled)
                bypassed = false
            }
            restored[stage] = StageValue(
                stage: stage,
                exactIdentityAtZero: descriptor.exactIdentityAtZero,
                control: control,
                isBypassed: bypassed
            )
        }
        screenAmount = state.screen.storedAmount
        screenIsBypassed = state.screen.isBypassed
        stages = restored
        invalidateParameters()
    }

    func setDiscreteEnabled(_ enabled: Bool, stage: PhysicalStageID) throws {
        if stage == .capture(.developDemosaic), enabled,
           stageValue(.capture(.sensorReadout)).control == .discrete(enabled: false)
        {
            throw PhysicalModelStateError.invalidStageCombination
        }
        guard var value = stages[stage], case .discrete = value.control else {
            throw PhysicalModelStateError.stageIsNotDiscrete
        }
        value.control = .discrete(enabled: enabled)
        guard stages[stage] != value else { return }
        stages[stage] = value
        if stage == .capture(.sensorReadout), !enabled {
            if var noise = stages[.capture(.sensorCollection)],
               case let .continuous(_, limits) = noise.control
            {
                noise.control = .continuous(amount: 0, limits: limits)
                stages[.capture(.sensorCollection)] = noise
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
            screenIsBypassed: screenIsBypassed,
            stages: stages
        )
        isolatedStage = stage
        for candidate in PhysicalStageID.ordered where candidate != stage {
            guard var value = stages[candidate] else { continue }
            switch value.control {
            case .continuous:
                value.isBypassed = true
            case .discrete:
                value.control = .discrete(enabled: false)
            }
            stages[candidate] = value
        }
        if stage.domain == .screen, screenAmount == 0 { screenAmount = 1 }
        if stage.domain == .screen { screenIsBypassed = false }
        invalidateParameters()
    }

    func restoreIsolation() {
        guard let snapshot = isolationSnapshot else { return }
        screenAmount = snapshot.screenAmount
        screenIsBypassed = snapshot.screenIsBypassed
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
        let next = min(1, max(0, progress))
        if self.progress != next {
            self.progress = next
        }
    }

    func publishInteractive(
        _ snapshot: PhysicalMetalFrameSnapshot,
        elapsedSeconds: Double
    ) {
        computedQuality = snapshot.computedQuality
        effectiveDimensions = snapshot.effectiveDimensions
        diagnostics = decoratedDiagnostics(snapshot.diagnostics)
        lastInteractiveSeconds = max(0, elapsedSeconds)
    }

    func publishNative(_ snapshot: PhysicalMetalFrameSnapshot) {
        if computedQuality != snapshot.computedQuality {
            computedQuality = snapshot.computedQuality
        }
        if effectiveDimensions != snapshot.effectiveDimensions {
            effectiveDimensions = snapshot.effectiveDimensions
        }
        let nextDiagnostics = decoratedDiagnostics(snapshot.diagnostics)
        if diagnostics != nextDiagnostics {
            diagnostics = nextDiagnostics
        }
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

    func requestNativeCancellation() {
        guard frameState == .rendering else { return }
        cancelNativeWork?()
    }

    func confirmNativeCancellation() {
        nativeStartedAt = nil
        progress = 0
        frameState = completedFrame == nil ? .cancelled : .stale
    }

    func failNative() {
        guard frameState == .rendering else { return }
        nativeStartedAt = nil
        progress = 0
        frameState = .failed
    }

    private func activeCount(in domain: PhysicalDomainID) -> Int {
        if domain == .screen, screenIsBypassed { return 0 }
        return stages.values.filter { value in
            guard value.stage.domain == domain else { return false }
            if value.isBypassed { return false }
            return switch value.control {
            case let .continuous(amount, _): amount > 0
            case let .discrete(enabled): enabled
            }
        }.count
    }

    private func decoratedDiagnostics(
        _ source: [PhysicalStageDiagnostic]
    ) -> [PhysicalStageDiagnostic] {
        source.map { diagnostic in
            guard let suffix = bypassDiagnosticMessage(for: diagnostic.stage) else {
                return diagnostic
            }
            return PhysicalStageDiagnostic(
                stage: diagnostic.stage,
                state: diagnostic.state,
                progress: diagnostic.progress,
                elapsedNanoseconds: diagnostic.elapsedNanoseconds,
                message: diagnostic.message.isEmpty ? suffix : "\(diagnostic.message) · \(suffix)"
            )
        }
    }

    private func invalidateParameters(returnToSetup: Bool = true) {
        parameterRevision &+= 1
        if frameState == .rendering {
            cancelNativeWork?()
            nativeStartedAt = nil
            progress = 0
            frameState = completedFrame == nil ? .cancelled : .stale
        } else if frameState == .complete {
            frameState = .stale
        }
        if returnToSetup {
            switch quality {
            case .setup, .environmentSetup, .focusSetup:
                break
            case .draft, .medium, .high, .native:
                quality = .setup
            }
        }
        interactiveInvalidation?()
    }
}

enum PhysicalModelStateError: Error, Equatable {
    case unknownStage
    case stageIsNotContinuous
    case stageIsNotDiscrete
    case nativeAlreadyRendering
    case domainHasNoContinuousMaster
    case invalidStageCombination
    case invalidAuthoringState
}
