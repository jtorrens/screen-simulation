import StudioColor
import Testing
import AppKit

@Test func buildIdentityIsPinned() {
    #expect(StudioColorBuildIdentity.ocioVersion == "2.5.2")
    #expect(StudioColorBuildIdentity.configurationSHA256.count == 64)
}

@Test func rawPreviewDeclaresLinearACEScgForColorSync() throws {
    let raw = try #require(StudioColorOutputTransform.catalog.first {
        $0.id == "acescg-raw"
    })
    #expect(raw.declaredSignalDescription == "ACEScg lineal")
    #expect(raw.colorSpace?.name == CGColorSpace.acescgLinear)
}

@Test @MainActor func activeDisplayReportsScreenAndColorSyncProfile() throws {
    let screen = try #require(NSScreen.main)
    let info = StudioColorSystemDisplayInfo.current(screen: screen)
    #expect(info.displayID != nil)
    #expect(!info.displayName.isEmpty)
    #expect(!info.profileName.isEmpty)
    #expect(!info.systemColorSpaceName.isEmpty)
}

@Test func cpuPipelinePreservesAlphaAndExtendedRangeUntilOutput() throws {
    let pipeline = StudioColorPipeline()
    let frame = try pipeline.prepareInput(
        width: 2,
        height: 1,
        encodedRGBA: [-0.25, 0.18, 4.0, 0.5, 1.5, 0.0, 0.25, 1.0],
        input: StudioColorInputTransform.catalog.first { $0.id == "acescg" }!,
        alpha: .straight
    )
    #expect(frame.premultipliedRGBA[0] < 0)
    #expect(frame.premultipliedRGBA[2] > 1)
    #expect(frame.premultipliedRGBA[3] == 0.5)
}

@Test func displayRec709InverseRoundTripsThroughMatchingACESOutput() throws {
    let pipeline = StudioColorPipeline()
    let input = StudioColorInputTransform.catalog.first {
        $0.id == "display-rec709-aces2-sdr"
    }!
    let output = StudioColorOutputTransform.catalog.first {
        $0.id == "aces2-rec709-sdr-100"
    }!
    let samples: [Float] = [
        0, 0, 0, 1,
        1, 1, 1, 1,
        1, 0, 0, 1,
        0, 1, 0, 1,
        0, 0, 1, 1,
        0.18, 0.42, 0.73, 1,
    ]
    let frame = try pipeline.prepareInput(
        width: samples.count / 4,
        height: 1,
        encodedRGBA: samples,
        input: input,
        alpha: .straight
    )
    let result = try pipeline.cpuOracleRGBA8(frame, output: output)
    let expected = samples.map { UInt8((min(1, max(0, $0)) * 255).rounded()) }
    #expect(zip(result, expected).map { abs(Int($0) - Int($1)) }.max() ?? 0 <= 1)
}

@Test func acesHDRInverseRoundTripsThroughMatchingACESOutput() throws {
    try assertDisplayRoundtrip(
        inputID: "display-rec2100-pq-aces2-hdr-1000",
        display: "Rec.2100-PQ - Display",
        view: "ACES 2.0 - HDR 1000 nits (Rec.2020)",
        tolerance: 2e-4,
        samples: hdrRoundtripSamples
    )
}

@Test func dcmSDRUsesItsColorimetricContractAndRoundTrips() throws {
    let samples = roundtripSamples
    let pipeline = StudioColorPipeline()
    let input = StudioColorInputTransform.catalog.first {
        $0.id == "display-rec709-gamma24-dcm"
    }!
    let frame = try pipeline.prepareInput(
        width: samples.count / 4, height: 1, encodedRGBA: samples,
        input: input, alpha: .straight
    )
    var result = frame.premultipliedRGBA
    unpremultiply(&result)
    let processor = try StudioColorEngine.bundled().cachedColorSpaceProcessor(
        source: "ACEScg", destination: "Gamma 2.4 Encoded Rec.709"
    )
    try processor.apply(toRGBA: &result)
    #expect(zip(result, samples).map { abs($0 - $1) }.max() ?? 0 <= 3e-5)
}

@Test func dcmHDRUsesItsColorimetricContractAndRoundTrips() throws {
    try assertDisplayRoundtrip(
        inputID: "display-rec2100-pq-dcm",
        display: "Rec.2100-PQ - Display",
        view: "Video (colorimetric)",
        tolerance: 1e-3
    )
}

@Test @MainActor func metalMatchesCreditsCPUOracleForEveryOutput() throws {
    let pipeline = StudioColorPipeline()
    let display = try StudioColorMetalDisplay()
    var rgba: [Float] = [
        -0.25, 0.18, 4.0, 1,
        1, 0, 0, 1,
        0, 1, 0, 1,
        0, 0, 1, 1,
    ]
    for index in 0 ..< 4096 {
        let value = Float(index) / 1024 - 1
        rgba.append(contentsOf: [value, value * 0.37, value * 1.91, 1])
    }
    let frame = try StudioColorLinearFrame(
        width: rgba.count / 4,
        height: 1,
        premultipliedRGBA: rgba
    )
    for output in StudioColorOutputTransform.catalog {
        let gpu = try display.renderRGBA8(frame, output: output)
        let cpu = try pipeline.cpuOracleRGBA8(frame, output: output)
        let deltas = zip(gpu, cpu).map { abs(Int($0) - Int($1)) }
        #expect(deltas.max() ?? 0 <= 1, Comment(rawValue: output.label))
        let changed = deltas.filter { $0 != 0 }.count
        #expect(Double(changed) / Double(deltas.count) <= 0.005, Comment(rawValue: output.label))
    }
}

@Test @MainActor func continuousMetalInputGraphMatchesCPUOracle() throws {
    let pipeline = StudioColorPipeline()
    let display = try StudioColorMetalDisplay()
    let encoded: [Float] = [
        -0.25, 0.18, 4.0, 1,
        0.25, 0.5, 0.75, 0.5,
        1.5, 0.05, 0.001, 1,
    ]
    let input = StudioColorInputTransform.catalog[2]
    let cpuFrame = try pipeline.prepareInput(
        width: 3, height: 1, encodedRGBA: encoded, input: input, alpha: .straight
    )
    let metalFrame = try display.makeACEScgFrame(
        width: 3, height: 1, encodedRGBA: encoded, input: input, alpha: .straight
    )
    for output in StudioColorOutputTransform.catalog {
        let gpu = try display.renderRGBA8(metalFrame, output: output)
        let cpu = try pipeline.cpuOracleRGBA8(cpuFrame, output: output)
        #expect(zip(gpu, cpu).map { abs(Int($0) - Int($1)) }.max() ?? 0 <= 1)
    }
}

private func assertDisplayRoundtrip(
    inputID: String,
    display: String,
    view: String,
    tolerance: Float,
    samples: [Float] = roundtripSamples
) throws {
    let input = StudioColorInputTransform.catalog.first { $0.id == inputID }!
    let pipeline = StudioColorPipeline()
    let frame = try pipeline.prepareInput(
        width: samples.count / 4,
        height: 1,
        encodedRGBA: samples,
        input: input,
        alpha: .straight
    )
    var result = frame.premultipliedRGBA
    unpremultiply(&result)
    let processor = try StudioColorEngine.bundled().cachedDisplayProcessor(
        source: "ACEScg", display: display, view: view
    )
    try processor.apply(toRGBA: &result)
    let maximum = zip(result, samples).map { abs($0 - $1) }.max() ?? 0
    #expect(maximum <= tolerance, "maximum error \(maximum)")
}

private func unpremultiply(_ values: inout [Float]) {
    for offset in stride(from: 0, to: values.count, by: 4) {
        let alpha = values[offset + 3]
        if alpha > 0 {
            values[offset] /= alpha
            values[offset + 1] /= alpha
            values[offset + 2] /= alpha
        }
    }
}

private let roundtripSamples: [Float] = [
    0, 0, 0, 1,
    1, 1, 1, 1,
    0.03125, 0.03125, 0.03125, 1,
    0.18, 0.18, 0.18, 1,
    0.5, 0.5, 0.5, 1,
    0.73, 0.42, 0.09, 0.25,
]

private let hdrRoundtripSamples: [Float] = [
    0, 0, 0, 1,
    0.03125, 0.03125, 0.03125, 1,
    0.18, 0.18, 0.18, 1,
    0.5, 0.5, 0.5, 1,
    0.75, 0.75, 0.75, 1,
]
