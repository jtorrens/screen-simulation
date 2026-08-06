import Testing
import StudioColor
import QuartzCore
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
    let result = try stage.process(
        frame, device: resolved, amount: 0, placement: .stretch, color: color
    )
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
    let result = try stage.process(
        frame, device: resolved, amount: 1, placement: .stretch, color: color
    )
    let actual = try color.readLinearRGBA(result)
    #expect(actual.count == expected.count)
    #expect(zip(actual, expected).map { abs($0 - $1) }.max() ?? 0 < 0.003)
}

@Test @MainActor func devicePlacementUsesResolvedDeviceAspectWithoutMutatingPreset() throws {
    let color = try StudioColorMetalDisplay()
    let stage = try DeviceMetalStage()
    var definition = try #require(try RustDeviceCatalog.builtIns().first)
    definition.nativeWidth = 2
    definition.nativeHeight = 4
    let resolved = try definition.resolved()
    let source = [Float](repeating: 1, count: 4 * 4 * 4)
    let frame = try color.makeACEScgFrame(
        width: 4,
        height: 4,
        encodedRGBA: source,
        input: StudioColorInputTransform.catalog.first { $0.id == "acescg" }!,
        alpha: .straight
    )
    let fit = try stage.process(
        frame, device: resolved, amount: 1, placement: .fit, color: color
    )
    let values = try color.readLinearRGBA(fit)
    let topRowMaximum = values[0 ..< 4 * 4].max() ?? 0
    let middleOffset = 4 * 4
    let middleRowMaximum = values[middleOffset ..< middleOffset + 4 * 4].max() ?? 0
    #expect(topRowMaximum < 0.01)
    #expect(middleRowMaximum > topRowMaximum * 10)
    #expect(resolved.definition.nativeWidth == 2)
    #expect(resolved.definition.nativeHeight == 4)
}

@Test @MainActor func deviceStagePlaybackBenchmarkWhenRequested() throws {
    guard ProcessInfo.processInfo.environment["SCREEN_DEVICE_BENCHMARK"] == "1" else {
        return
    }
    let color = try StudioColorMetalDisplay()
    let stage = try DeviceMetalStage()
    let definition = try #require(try RustDeviceCatalog.builtIns().first)
    let resolved = try definition.resolved()
    let width = 960
    let height = 540
    var source = [Float](repeating: 0, count: width * height * 4)
    for offset in stride(from: 0, to: source.count, by: 4) {
        let x = Float((offset / 4) % width) / Float(width - 1)
        source[offset] = x
        source[offset + 1] = 0.18
        source[offset + 2] = 1 - x
        source[offset + 3] = 1
    }
    let frame = try color.makeACEScgFrame(
        width: width,
        height: height,
        encodedRGBA: source,
        input: StudioColorInputTransform.catalog.first { $0.id == "acescg" }!,
        alpha: .straight
    )
    var milliseconds: [Double] = []
    for _ in 0..<30 {
        let started = CACurrentMediaTime()
        _ = try stage.process(
            frame, device: resolved, amount: 1, placement: .stretch, color: color
        )
        milliseconds.append((CACurrentMediaTime() - started) * 1_000)
    }
    milliseconds.sort()
    let median = milliseconds[milliseconds.count / 2]
    let p95 = milliseconds[Int(Double(milliseconds.count - 1) * 0.95)]
    print("DEVICE_STAGE_960x540 median_ms=\(median) p95_ms=\(p95)")
    #expect(p95 < 41.67)
}
