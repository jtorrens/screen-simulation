import Foundation
import Combine
import Testing
@testable import ScreenSimulationNative

@Test @MainActor func physicalModelUsesOneSetOfOrderedContractContributions() throws {
    let model = PhysicalModelController()
    #expect(model.orderedContributions.map(\.stage) == PhysicalStageID.ordered)
    #expect(model.screenAmount == 1)
    #expect(throws: PhysicalModelStateError.domainHasNoContinuousMaster) {
        try model.setDomainAmount(1, domain: .capture)
    }
    try model.setDomainAmount(1.5, domain: .screen)
    try model.setContinuousAmount(2, stage: .screen(.subpixelGeometry))
    #expect(model.screenAmount == 1.5)
    #expect(model.stageValue(.screen(.subpixelGeometry)).control ==
        .continuous(amount: 2, limits: .standard))
    try model.setContinuousAmount(1.25, stage: .screen(.coverGlass))
    #expect(model.stageValue(.screen(.coverGlass)).amount == 1.25)
}

@Test @MainActor func isolationRestoresTheExactPriorAuthoringState() throws {
    let model = PhysicalModelController()
    try model.setDomainAmount(1.3, domain: .screen)
    try model.setContinuousAmount(1.8, stage: .screen(.subpixelGeometry))
    let prior = model.orderedContributions
    try model.toggleIsolation(.screen(.emission))
    #expect(model.isolatedStage == .screen(.emission))
    #expect(model.stageValue(.screen(.subpixelGeometry)).amount == 1.8)
    #expect(model.stageValue(.screen(.subpixelGeometry)).isBypassed)
    #expect(model.orderedContributions.first {
        $0.stage == .screen(.subpixelGeometry)
    }?.amount == 0)
    try model.toggleIsolation(.screen(.emission))
    #expect(model.isolatedStage == nil)
    #expect(model.screenAmount == 1.3)
    #expect(model.orderedContributions == prior)
}

@Test @MainActor func continuousBypassPreservesStoredValueAndRestoresItExactly() throws {
    let model = PhysicalModelController()
    let stage = PhysicalStageID.screen(.temporal)
    try model.setContinuousAmount(1.35, stage: stage)
    try model.setContinuousBypassed(true, stage: stage)
    #expect(model.stageValue(stage).amount == 1.35)
    #expect(model.orderedContributions.first { $0.stage == stage }?.amount == 0)
    #expect(model.bypassDiagnosticMessage(for: stage)?.contains("BYPASSED") == true)

    // Editing while bypassed prepares the next active value without affecting evaluation.
    try model.setContinuousAmount(1.7, stage: stage)
    #expect(model.stageValue(stage).amount == 1.7)
    #expect(model.orderedContributions.first { $0.stage == stage }?.amount == 0)
    try model.setContinuousBypassed(false, stage: stage)
    #expect(model.orderedContributions.first { $0.stage == stage }?.amount == 1.7)

    try model.setDomainAmount(1.4, domain: .screen)
    try model.setDomainBypassed(true, domain: .screen)
    #expect(model.screenAmount == 1.4)
    #expect(model.effectiveScreenAmount == 0)
    try model.setDomainBypassed(false, domain: .screen)
    #expect(model.effectiveScreenAmount == 1.4)
}

@Test @MainActor func bypassAndStoredAmountsPersistAsSeparateAuthoringState() throws {
    let source = PhysicalModelController()
    try source.setContinuousAmount(1.65, stage: .capture(.lens))
    try source.setContinuousBypassed(true, stage: .capture(.lens))
    try source.setDomainAmount(1.25, domain: .screen)
    try source.setDomainBypassed(true, domain: .screen)

    let data = try JSONEncoder().encode(source.authoringState)
    let decoded = try JSONDecoder().decode(PhysicalModelAuthoringState.self, from: data)
    let restored = PhysicalModelController()
    try restored.restoreAuthoringState(decoded)

    #expect(restored.authoringState == source.authoringState)
    #expect(restored.stageValue(.capture(.lens)).amount == 1.65)
    #expect(restored.orderedContributions.first { $0.stage == .capture(.lens) }?.amount == 0)
    #expect(restored.screenAmount == 1.25)
    #expect(restored.effectiveScreenAmount == 0)
}

@Test @MainActor func workspaceBypassParticipatesInNativeUndo() async throws {
    let workspace = WorkspaceModel()
    let undo = UndoManager()
    let stage = PhysicalStageID.screen(.environment)
    workspace.changePhysicalStageBypass(true, stage: stage, undoManager: undo)
    #expect(workspace.physicalModel.stageValue(stage).isBypassed)
    undo.undo()
    await Task.yield()
    #expect(!workspace.physicalModel.stageValue(stage).isBypassed)
}

@Test @MainActor func nativeResultBecomesStaleAndCancellationIsExplicit() throws {
    let model = PhysicalModelController()
    try model.beginNative()
    #expect(model.frameState == .rendering)
    model.updateNativeProgress(0.4)
    #expect(model.progress == 0.4)
    let dimensions = try PhysicalDimensions(width: 750, height: 1_334)
    model.completeNative(nativeDimensions: dimensions, effectiveDimensions: dimensions)
    #expect(model.frameState == .complete)
    try model.setContinuousAmount(1.2, stage: .screen(.emission))
    #expect(model.frameState == .stale)
    #expect(model.completedFrame?.nativeDimensions == dimensions)
    try model.beginNative()
    model.requestNativeCancellation()
    #expect(model.frameState == .rendering)
    model.confirmNativeCancellation()
    #expect(model.frameState == .stale)
    #expect(model.completedFrame?.nativeDimensions == dimensions)
    #expect(model.progress == 0)
}

@Test @MainActor func changingTheSourcePatternInvalidatesTheNativeResult() throws {
    let workspace = WorkspaceModel()
    let dimensions = try PhysicalDimensions(width: 8064, height: 6048)
    try workspace.physicalModel.beginNative()
    workspace.physicalModel.completeNative(
        nativeDimensions: dimensions,
        effectiveDimensions: dimensions
    )
    #expect(workspace.testNativeRenderButtonState == .complete)

    workspace.choosePattern(.eyeChart, undoManager: nil)

    #expect(workspace.physicalModel.frameState == .stale)
    #expect(workspace.testNativeRenderButtonState == .outdated)
}

@Test @MainActor func editingParametersPreservesTheExplicitSetupTool() throws {
    let model = PhysicalModelController()

    model.setQuality(.focusSetup)
    try model.setContinuousAmount(1.2, stage: .capture(.lens))
    #expect(model.quality == .focusSetup)

    model.setQuality(.environmentSetup)
    try model.setContinuousAmount(1.1, stage: .screen(.environment))
    #expect(model.quality == .environmentSetup)

    model.setQuality(.native)
    try model.setContinuousAmount(1.1, stage: .screen(.emission))
    #expect(model.quality == .setup)
}

@Test @MainActor func identicalNativeProgressDoesNotRepublishObservableState() throws {
    let model = PhysicalModelController()
    try model.beginNative()
    let dimensions = try PhysicalDimensions(width: 8064, height: 6048)
    let snapshot = PhysicalMetalFrameSnapshot(
        frame: nil,
        nativeDimensions: dimensions,
        effectiveDimensions: dimensions,
        computedQuality: .native,
        returnedIntermediate: .developedACEScg,
        state: .rendering,
        progress: 0.25,
        diagnostics: [],
        parameterRevision: model.parameterRevision,
        parameterHash: try PhysicalParameterHash(bytes: Array(repeating: 0, count: 32))
    )
    var publications = 0
    let subscription = model.objectWillChange.sink { publications += 1 }
    model.publishNative(snapshot)
    publications = 0
    model.publishNative(snapshot)
    #expect(publications == 0)
    _ = subscription
}

private extension PhysicalModelController.StageValue {
    var amount: Double? {
        guard case let .continuous(amount, _) = control else { return nil }
        return amount
    }
}
