import StudioColor
import Testing
@testable import ScreenSimulationNative

@Test func rustDeviceCatalogIsTheSinglePresetAuthority() throws {
    let devices = try RustDeviceCatalog.builtIns()
    #expect(devices.count == 9)
    #expect(Set(devices.map(\.id)).count == devices.count)
    let macBook = try #require(
        devices.first { $0.id == "lcd-macbook-pro-retina-14" }
    )
    #expect(macBook.nativeWidth == 3_024)
    #expect(macBook.nativeHeight == 1_964)
    #expect(abs(macBook.activeWidthMeters - 0.3024) < 0.000_001)
    #expect(abs(macBook.pixelsPerInch - 254) < 0.2)
    #expect(macBook.panelTechnology == .ipsLCD)
    #expect(macBook.defaultCoverGlassPresetID == "cover-glossy-strong-ar")
    _ = try macBook.resolved()
}

@Test func invalidDeviceIsRejectedByTheRustPhysicalContract() throws {
    var device = try #require(try RustDeviceCatalog.builtIns().first)
    device.whiteLevelNits = device.blackLevelNits
    #expect(throws: DeviceDomainError.self) {
        try device.resolved()
    }
}

@Test func resolvedDeviceIsAnImmutableSnapshot() throws {
    var definition = try #require(try RustDeviceCatalog.builtIns().first)
    let resolved = try definition.resolved()
    definition.name = "Editado después"
    #expect(resolved.definition.name != definition.name)
}

@Test @MainActor func physicalBridgeAmountZeroPreservesTheExactACEScgTexture() async throws {
    let color = try StudioColorMetalDisplay()
    let frame = try color.makeACEScgFrame(
        width: 2,
        height: 2,
        encodedRGBA: [
            -0.1, 0.18, 1.25, 1,
            0.5, 0.5, 0.5, 0.75,
            1, 0, 0, 1,
            0, 1, 0, 1,
        ],
        input: StudioColorInputTransform.catalog.first { $0.id == "acescg" }!,
        alpha: .straight
    )
    var definition = try #require(try RustDeviceCatalog.builtIns().first)
    definition.nativeWidth = 2
    definition.nativeHeight = 2
    let job = try PhysicalMetalFrameEngine().submit(
        sourceACEScg: frame,
        deviceSignal: frame,
        frame: try PhysicalFrameSelection(
            frameIndex: 0,
            timeNumerator: 0,
            timeDenominator: 24
        ),
        resolvedDevice: try definition.resolved(),
        quality: .draft,
        screenAmount: 0,
        captureAmount: 0,
        contributions: try contributions(emission: 1, geometry: 1),
        requestedDimensions: try PhysicalDimensions(width: 2, height: 2),
        cancellationIdentity: PhysicalFrameIdentity(high: 1, low: 1),
        progressIdentity: PhysicalFrameIdentity(high: 1, low: 1),
        parameterRevision: 1,
        parameterHash: try PhysicalParameterHash(bytes: [UInt8](repeating: 0, count: 32)),
        rasterPlacement: .fit
    )
    let result = try await completedSnapshot(job)
    let expectedDimensions = try PhysicalDimensions(width: 2, height: 2)
    #expect(result.state == .complete)
    #expect(result.frame?.texture === frame.texture)
    #expect(result.effectiveDimensions == expectedDimensions)
}

@Test @MainActor func physicalBridgeEvaluatesTheRealBGRPanelAndReportsDiagnostics() async throws {
    let color = try StudioColorMetalDisplay()
    let frame = try color.makeACEScgFrame(
        width: 3,
        height: 2,
        encodedRGBA: [Float](repeating: 0.5, count: 3 * 2 * 4),
        input: StudioColorInputTransform.catalog.first { $0.id == "acescg" }!,
        alpha: .straight
    )
    var definition = try #require(try RustDeviceCatalog.builtIns().first)
    definition.nativeWidth = 3
    definition.nativeHeight = 2
    definition.stripeLayout = .bgr
    let job = try PhysicalMetalFrameEngine().submit(
        sourceACEScg: frame,
        deviceSignal: frame,
        frame: try PhysicalFrameSelection(
            frameIndex: 0,
            timeNumerator: 0,
            timeDenominator: 24
        ),
        resolvedDevice: try definition.resolved(),
        quality: .high,
        screenAmount: 1,
        captureAmount: 0,
        contributions: try contributions(emission: 1, geometry: 1),
        requestedDimensions: try PhysicalDimensions(width: 3, height: 2),
        cancellationIdentity: PhysicalFrameIdentity(high: 2, low: 2),
        progressIdentity: PhysicalFrameIdentity(high: 2, low: 2),
        parameterRevision: 2,
        parameterHash: try PhysicalParameterHash(bytes: [UInt8](repeating: 1, count: 32)),
        rasterPlacement: .fillCrop
    )
    let result = try await completedSnapshot(job)
    #expect(result.frame != nil)
    #expect(result.computedQuality == .high)
    #expect(result.diagnostics.contains { $0.stage == .screen(.emission) })
    #expect(result.diagnostics.contains { $0.stage == .screen(.subpixelGeometry) })
}

private func contributions(
    emission: Double,
    geometry: Double
) throws -> [PhysicalStageContribution] {
    var result: [PhysicalStageContribution] = []
    for stage in PhysicalStageID.ordered {
        let amount: Double = switch stage {
        case .screen(.emission): emission
        case .screen(.subpixelGeometry): geometry
        default: 0
        }
        let discrete = stage == .capture(.sensorCFA)
            || stage == .capture(.developDemosaic)
        let control: PhysicalControlSemantics = discrete
            ? .discrete(enabled: false)
            : .continuous(amount: amount, limits: .standard)
        result.append(try PhysicalStageContribution(
            stage: stage,
            control: control,
            exactIdentityAtZero: !discrete
        ))
    }
    return result
}

@MainActor
private func completedSnapshot(
    _ job: PhysicalMetalFrameJob
) async throws -> PhysicalMetalFrameSnapshot {
    for _ in 0..<1_000 {
        let snapshot = try job.snapshot()
        if snapshot.state == .complete { return snapshot }
        if snapshot.state == .failed {
            throw PhysicalMetalFrameEngineError.bridge(
                snapshot.diagnostics.last?.message ?? "physical test job failed"
            )
        }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw PhysicalMetalFrameEngineError.bridge("physical test job timed out")
}
