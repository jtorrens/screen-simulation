import StudioColor
import Testing
@testable import ScreenSimulationNative

@Test @MainActor func unifiedPhysicalABIAmountZeroPreservesSourceTexture() async throws {
    let fixture = try makePhysicalFixture()
    let job = try submit(
        fixture: fixture,
        screenAmount: 0,
        contributions: try contributions(),
        intermediate: .developedACEScg,
        identity: 1
    )
    let result = try await terminalSnapshot(job)
    #expect(result.state == .complete)
    #expect(result.returnedIntermediate == .developedACEScg)
    #expect(result.frame?.texture === fixture.source.texture)
}

@Test @MainActor func unifiedPhysicalABIReturnsEverySupportedIntermediate() async throws {
    let fixture = try makePhysicalFixture()
    for (offset, intermediate) in PhysicalIntermediate.supportedDiagnostics.enumerated() {
        let job = try submit(
            fixture: fixture,
            screenAmount: 1,
            contributions: try contributions(),
            intermediate: intermediate,
            identity: UInt64(10 + offset)
        )
        let result = try await terminalSnapshot(job)
        #expect(result.state == .complete)
        #expect(result.returnedIntermediate == intermediate)
        #expect(result.frame != nil)
        #expect(result.diagnostics.map(\.stage) == PhysicalStageID.ordered)
    }
}

@Test @MainActor func unifiedPhysicalABIRejectsUnsupportedActiveStage() async throws {
    let fixture = try makePhysicalFixture()
    var values = try contributions()
    let index = try #require(values.firstIndex { $0.stage == .screen(.coverGlass) })
    values[index] = try PhysicalStageContribution(
        stage: .screen(.coverGlass),
        control: .continuous(amount: 1, limits: .standard),
        exactIdentityAtZero: true
    )
    #expect(throws: PhysicalMetalFrameEngineError.self) {
        _ = try submit(
            fixture: fixture,
            screenAmount: 1,
            contributions: values,
            intermediate: .developedACEScg,
            identity: 30
        )
    }
}

@Test @MainActor func unifiedPhysicalABICoversTopologyPlacementAndSpreadMatrix() async throws {
    for stripe in [DeviceStripeLayout.rgb, .bgr] {
        let fixture = try makePhysicalFixture(stripe: stripe, blackMatrix: 0.18)
        for placement in PhysicalRasterPlacement.allCases {
            for spread in [0.0, 1.0, 2.5] {
                let identity = UInt64(
                    100 + Int(stripe == .bgr ? 50 : 0)
                        + Int(placement.rawValue) * 10 + Int(spread * 2)
                )
                let job = try submit(
                    fixture: fixture,
                    screenAmount: 1,
                    contributions: try contributions(spreadAmount: spread),
                    intermediate: .developedACEScg,
                    identity: identity,
                    placement: placement
                )
                let result = try await terminalSnapshot(job)
                #expect(result.state == .complete)
                #expect(result.frame != nil)
                #expect(result.progress == 1)
                #expect(result.diagnostics.count == 12)
            }
        }
    }
}

@Test @MainActor func unifiedPhysicalABICancelsNativeWithMatchingIdentity() async throws {
    let fixture = try makePhysicalFixture(useNativeDeviceRaster: true)
    let job = try submit(
        fixture: fixture,
        screenAmount: 1,
        contributions: try contributions(),
        intermediate: .developedACEScg,
        identity: 220,
        quality: .native,
        dimensions: try PhysicalDimensions(
            width: fixture.device.definition.nativeWidth,
            height: fixture.device.definition.nativeHeight
        )
    )
    #expect(job.cancel())
    let result = try await terminalSnapshot(job)
    #expect(result.state == .cancelled)
}

private struct PhysicalFixture {
    let source: StudioColorMetalFrame
    let deviceSignal: StudioColorMetalFrame
    let device: ResolvedDevice
    let pipeline: PhysicalPipelineResolvedState
}

@MainActor
private func makePhysicalFixture(
    stripe: DeviceStripeLayout = .rgb,
    blackMatrix: Double = 0.12,
    useNativeDeviceRaster: Bool = false
) throws -> PhysicalFixture {
    let display = try StudioColorMetalDisplay()
    let source = try display.makeACEScgFrame(
        width: 4,
        height: 4,
        encodedRGBA: (0..<16).flatMap { index -> [Float] in
            let value = Float(index) / 15
            return [value, 1 - value, value * 1.25 - 0.1, Float(index) / 15]
        },
        input: StudioColorInputTransform.catalog.first { $0.id == "acescg" }!,
        alpha: .straight
    )
    let output = StudioColorOutputTransform.catalog.first {
        $0.id == "aces2-srgb-sdr-100"
    }!
    let signal = try display.transformToMetalFrame(source, output: output)
    var device = try #require(try RustDeviceCatalog.builtIns().first)
    if !useNativeDeviceRaster {
        device.nativeWidth = 4
        device.nativeHeight = 4
    }
    device.stripeLayout = stripe
    device.blackMatrixFraction = blackMatrix
    let cover = try #require(
        try RustCoverGlassCatalog.builtIns().first {
            $0.id == device.defaultCoverGlassPresetID
        }
    )
    return PhysicalFixture(
        source: source,
        deviceSignal: signal,
        device: try device.resolved(),
        pipeline: try .inactiveDownstreamStages(coverGlass: cover)
    )
}

private func contributions(
    spreadAmount: Double = 1
) throws -> [PhysicalStageContribution] {
    try PhysicalStageID.ordered.map { stage in
        let implemented = stage.isImplementedByUnifiedPipeline
        let discrete = stage == .capture(.sensorCFA)
            || stage == .capture(.developDemosaic)
        let amount = stage == .screen(.panelLightSpread)
            ? spreadAmount : implemented ? 1 : 0
        return try PhysicalStageContribution(
            stage: stage,
            control: discrete
                ? .discrete(enabled: false)
                : .continuous(amount: amount, limits: .standard),
            exactIdentityAtZero: !discrete
        )
    }
}

@MainActor
private func submit(
    fixture: PhysicalFixture,
    screenAmount: Double,
    contributions: [PhysicalStageContribution],
    intermediate: PhysicalIntermediate,
    identity: UInt64,
    placement: PhysicalRasterPlacement = .fit,
    quality: PhysicalQuality = .draft,
    dimensions: PhysicalDimensions? = nil
) throws -> PhysicalMetalFrameJob {
    let spreadAmount = try #require(contributions.first {
        $0.stage == .screen(.panelLightSpread)
    }?.amount)
    var effectiveDefinition = fixture.device.definition
    effectiveDefinition.panelLightSpread.characterStrength = spreadAmount
    return try PhysicalMetalFrameEngine().submit(
        sourceACEScg: fixture.source,
        deviceSignal: fixture.deviceSignal,
        frame: try PhysicalFrameSelection(
            frameIndex: 0,
            timeNumerator: 0,
            timeDenominator: 24
        ),
        resolvedDevice: try effectiveDefinition.resolved(),
        resolvedPipeline: fixture.pipeline,
        quality: quality,
        screenAmount: screenAmount,
        captureAmount: 0,
        contributions: contributions,
        requestedDimensions: try dimensions
            ?? PhysicalDimensions(width: 4, height: 4),
        cancellationIdentity: .init(high: identity, low: identity),
        progressIdentity: .init(high: identity, low: identity),
        parameterRevision: identity,
        parameterHash: try PhysicalParameterHash(
            bytes: [UInt8](repeating: UInt8(identity), count: 32)
        ),
        rasterPlacement: placement,
        requestedIntermediate: intermediate
    )
}

@MainActor
private func terminalSnapshot(
    _ job: PhysicalMetalFrameJob
) async throws -> PhysicalMetalFrameSnapshot {
    for _ in 0..<2_000 {
        let result = try job.snapshot()
        if [.complete, .failed, .cancelled].contains(result.state) {
            return result
        }
        try await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("El job físico no alcanzó un estado terminal.")
    return try job.snapshot()
}
