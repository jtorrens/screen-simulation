import ScreenPhysicalBridge
import Testing
@testable import ScreenSimulationNative

@Test func generalOverviewContainsEveryAuthoritativeContinuousCategoryWithoutCaptureMaster() {
    #expect(PhysicalStageID.generalOverviewContinuous == [
        .screen(.temporal),
        .screen(.coverGlass),
        .screen(.environment),
        .capture(.lens),
        .capture(.exposureShutter),
        .capture(.noise),
    ])
    #expect(!PhysicalStageID.generalOverviewContinuous.contains(.capture(.sensorCFA)))
    #expect(!PhysicalStageID.generalOverviewContinuous.contains(.capture(.developDemosaic)))
}

@Test func physicalContractHasOneStableOrderedDomainAndStageNamespace() {
    #expect(PhysicalFrameRequest.abiVersion == 2)
    #expect(PhysicalQuality.draft.rawValue == SCREEN_PHYSICAL_QUALITY_DRAFT.rawValue)
    #expect(PhysicalQuality.native.rawValue == SCREEN_PHYSICAL_QUALITY_NATIVE.rawValue)
    #expect(PhysicalDomainID.screen.rawValue == SCREEN_PHYSICAL_DOMAIN_SCREEN.rawValue)
    #expect(PhysicalDomainID.capture.rawValue == SCREEN_PHYSICAL_DOMAIN_CAPTURE.rawValue)
    #expect(ScreenPhysicalSection.emission.rawValue ==
        SCREEN_PHYSICAL_STAGE_SCREEN_EMISSION.rawValue)
    #expect(CapturePhysicalSection.developDemosaic.rawValue ==
        SCREEN_PHYSICAL_STAGE_CAPTURE_DEVELOP_DEMOSAIC.rawValue)
    #expect(PhysicalRasterPlacement.allCases.map(\.rawValue) == [0, 1, 2, 3])
    #expect(PhysicalRasterPlacement.fit.rawValue == SCREEN_PHYSICAL_RASTER_FIT.rawValue)
    #expect(PhysicalRasterPlacement.fillCrop.rawValue ==
        SCREEN_PHYSICAL_RASTER_FILL_CROP.rawValue)
    #expect(PhysicalRasterPlacement.stretch.rawValue ==
        SCREEN_PHYSICAL_RASTER_STRETCH.rawValue)
    #expect(PhysicalRasterPlacement.oneToOne.rawValue ==
        SCREEN_PHYSICAL_RASTER_ONE_TO_ONE.rawValue)
    #expect(PhysicalQuality.allCases.map(\.rawValue) == [0, 1, 2, 3])
    #expect(PhysicalDomainID.allCases.map(\.rawValue) == [0x100, 0x200])
    #expect(PhysicalStageID.ordered.map(\.id) == [
        0x101, 0x102, 0x103, 0x104, 0x105, 0x106,
        0x201, 0x202, 0x203, 0x204, 0x205, 0x206,
    ])
    #expect(PhysicalStageID.ordered.map(\.domain) ==
        Array(repeating: .screen, count: 6)
        + Array(repeating: .capture, count: 6))
}

@Test func continuousContributionEnforcesVisualAndSafeRanges() throws {
    let limits = PhysicalContributionLimits.standard
    #expect(limits.visualRange == 0 ... 2)
    #expect(limits.safeRange == 0 ... 4)
    let bypass = try PhysicalStageContribution(
        stage: .screen(.emission),
        control: .continuous(amount: 0, limits: limits),
        exactIdentityAtZero: true
    )
    let physical = try PhysicalStageContribution(
        stage: .screen(.emission),
        control: .continuous(amount: 1, limits: limits),
        exactIdentityAtZero: true
    )
    let artistic = try PhysicalStageContribution(
        stage: .screen(.emission),
        control: .continuous(amount: 4, limits: limits),
        exactIdentityAtZero: true
    )
    #expect(bypass.amount == 0)
    #expect(physical.amount == 1)
    #expect(artistic.amount == 4)
    #expect(throws: PhysicalContractError.self) {
        try PhysicalStageContribution(
            stage: .screen(.emission),
            control: .continuous(amount: 4.01, limits: limits),
            exactIdentityAtZero: true
        )
    }
}

@Test func discreteContributionHasNoInventedContinuousAmount() throws {
    let cfa = try PhysicalStageContribution(
        stage: .capture(.sensorCFA),
        control: .discrete(enabled: true),
        exactIdentityAtZero: false
    )
    #expect(cfa.amount == nil)
    #expect(cfa.control == .discrete(enabled: true))
}

@Test func frameStateContractSeparatesStaleRenderingCancelAndCompletion() {
    #expect(PhysicalFrameState.idle.canTransition(to: .rendering))
    #expect(PhysicalFrameState.rendering.canTransition(to: .cancelled))
    #expect(PhysicalFrameState.rendering.canTransition(to: .complete))
    #expect(PhysicalFrameState.complete.canTransition(to: .stale))
    #expect(PhysicalFrameState.stale.canTransition(to: .rendering))
    #expect(!PhysicalFrameState.idle.canTransition(to: .complete))
    #expect(!PhysicalFrameState.cancelled.canTransition(to: .complete))
    #expect(!PhysicalFrameState.stale.canTransition(to: .complete))
}

@Test func frameAndHashRejectMalformedBoundaryValues() throws {
    _ = try PhysicalFrameSelection(frameIndex: 0, timeNumerator: 0, timeDenominator: 24)
    _ = try PhysicalDimensions(width: 1, height: 1)
    _ = try PhysicalParameterHash(bytes: Array(repeating: 0, count: 32))
    #expect(throws: PhysicalContractError.self) {
        try PhysicalFrameSelection(frameIndex: -1, timeNumerator: 0, timeDenominator: 24)
    }
    #expect(throws: PhysicalContractError.self) {
        try PhysicalFrameSelection(frameIndex: 0, timeNumerator: 0, timeDenominator: 0)
    }
    #expect(throws: PhysicalContractError.self) {
        try PhysicalDimensions(width: 0, height: 1)
    }
    #expect(throws: PhysicalContractError.self) {
        try PhysicalParameterHash(bytes: [])
    }
}
