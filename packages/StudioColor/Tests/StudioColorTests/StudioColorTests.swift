import StudioColor
import Testing

@Test func buildIdentityIsPinned() {
    #expect(StudioColorBuildIdentity.ocioVersion == "2.5.2")
    #expect(StudioColorBuildIdentity.configurationSHA256.count == 64)
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
