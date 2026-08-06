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
    #expect(model.stageValue(.screen(.subpixelGeometry)).amount == 0)
    try model.toggleIsolation(.screen(.emission))
    #expect(model.isolatedStage == nil)
    #expect(model.screenAmount == 1.3)
    #expect(model.orderedContributions == prior)
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
    model.cancelNative()
    #expect(model.frameState == .cancelled)
    #expect(model.progress == 0)
}

private extension PhysicalModelController.StageValue {
    var amount: Double? {
        guard case let .continuous(amount, _) = control else { return nil }
        return amount
    }
}
