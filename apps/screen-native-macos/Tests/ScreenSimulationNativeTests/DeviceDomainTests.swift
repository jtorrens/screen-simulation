import Testing
import StudioColor
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

@Test @MainActor func deviceMetalAmountZeroIsTheExactInputTexture() throws {
    let color = try StudioColorMetalDisplay()
    let stage = try DeviceMetalStage()
    let definition = try #require(try RustDeviceCatalog.builtIns().first)
    let resolved = try definition.resolved()
    let source: [Float] = [-0.1, 0.18, 1.25, 1]
    let frame = try color.makeACEScgFrame(
        width: 1,
        height: 1,
        encodedRGBA: source,
        input: StudioColorInputTransform.catalog.first { $0.id == "acescg" }!,
        alpha: .straight
    )
    let result = try stage.process(frame, device: resolved, amount: 0, color: color)
    #expect(result === frame)
    #expect(result.texture === frame.texture)
}

@Test @MainActor func deviceMetalMatchesTheRustBatchOracleAtAmountOne() throws {
    let color = try StudioColorMetalDisplay()
    let stage = try DeviceMetalStage()
    let definition = try #require(
        try RustDeviceCatalog.builtIns().first {
            $0.id == "lcd-asus-proart-pa329cv"
        }
    )
    let resolved = try definition.resolved()
    let source: [Float] = [
        -0.1, 0.0, 0.18, 1,
        0.5, 0.5, 0.5, 0.75,
        1.0, 0.2, 1.25, 1,
    ]
    let frame = try color.makeACEScgFrame(
        width: 3,
        height: 1,
        encodedRGBA: source,
        input: StudioColorInputTransform.catalog.first { $0.id == "acescg" }!,
        alpha: .straight
    )
    let deviceTransform = StudioColorOutputTransform.catalog.first {
        $0.id == "aces2-srgb-sdr-100"
    }!
    let deviceCode = try color.renderRGBAFloat(frame, output: deviceTransform)
    let expected = try resolved.cpuOracle(deviceCode: deviceCode)
    let result = try stage.process(frame, device: resolved, amount: 1, color: color)
    let actual = try color.readLinearRGBA(result)
    #expect(actual.count == expected.count)
    #expect(zip(actual, expected).map { abs($0 - $1) }.max() ?? 0 < 0.003)
}
