@preconcurrency import AVFoundation
import Foundation
import CoreMedia
import Metal
import QuartzCore
import StudioColor
import StudioMedia
import Testing
@testable import ScreenSimulationNative

@Test func diagnosticPNGPreservesSixteenBitSamplesAndMetadata() throws {
    let metadata = Data("{\"precision\":16}".utf8)
    let png = try FrameCheckPNG.encode(
        rgba16: [0, 1, 32_768, 65_535, 65_535, 32_768, 1, 65_535],
        width: 2,
        height: 1,
        colorSpace: nil,
        metadata: metadata
    )
    // PNG IHDR stores the sample bit depth immediately after width and height.
    #expect(png.count > 24)
    #expect(png[png.startIndex + 24] == 16)
    #expect(FrameCheckPNG.metadata(in: png) == metadata)
}

@Test @MainActor func rangeRenderWritesMovieAndCompleteImageSequences() async throws {
    let display = try StudioColorMetalDisplay()
    let width = 64
    let height = 36
    let values = [Float](repeating: 0.18, count: width * height * 4)
        .enumerated().map { $0.offset % 4 == 3 ? 1 : $0.element }
    let frame = try display.makeACEScgFrame(
        width: width, height: height, encodedRGBA: values,
        input: StudioColorInputTransform.catalog[2], alpha: .straight
    )
    let rgba16 = try display.renderRGBA16(
        frame,
        output: StudioColorOutputTransform.catalog[0]
    )
    #expect(rgba16.count == width * height * 4)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-native-output-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let movie = try await NativeOutputRenderer.render(
        configuration: renderConfiguration(
            format: .h264High, preset: StudioRenderPreset.builtIns[0],
            alpha: .ignore, signalRange: .video, frameRange: 0 ... 2
        ),
        destination: root.appendingPathComponent("smoke.mp4"),
        audioSource: nil,
        display: display, frameProvider: { _ in frame }, progress: { _, _ in }
    )
    #expect(FileManager.default.fileExists(atPath: movie.path))

    let exrDirectory = root.appendingPathComponent("exr")
    _ = try await NativeOutputRenderer.render(
        configuration: renderConfiguration(
            format: .openEXR, preset: StudioRenderPreset.builtIns[5],
            alpha: .premultiplied, signalRange: .full, frameRange: 7 ... 8
        ),
        destination: exrDirectory, audioSource: nil,
        display: display, frameProvider: { _ in frame }, progress: { _, _ in }
    )
    let ownedEXRDirectory = exrDirectory.appendingPathComponent("ScreenSimulation")
    #expect(FileManager.default.fileExists(
        atPath: ownedEXRDirectory.appendingPathComponent("ScreenSimulation-00000007.exr").path
    ))
    #expect(FileManager.default.fileExists(
        atPath: ownedEXRDirectory.appendingPathComponent("ScreenSimulation-00000008.exr").path
    ))

    let png = root.appendingPathComponent("current.png")
    try NativeOutputRenderer.renderCurrentFrame(
        frame: frame, displayTransform: StudioColorOutputTransform.catalog[0],
        metadata: [
            "schema": FrameCheckPNG.metadataKeyword,
            "schemaVersion": 1,
            "producer": ["application": "SCREEN Simulation Tests"],
        ],
        destination: png, display: display
    )
    let pngData = try Data(contentsOf: png)
    let metadata = try #require(FrameCheckPNG.metadata(in: pngData))
    let document = try #require(
        JSONSerialization.jsonObject(with: metadata) as? [String: Any]
    )
    #expect(document["schema"] as? String == FrameCheckPNG.metadataKeyword)
    #expect((document["hashes"] as? [String: String])?["pixelRGBA8SHA256"] != nil)
}

@Test @MainActor func acescgEXRStraightAlphaRoundtripPreservesHalfFloatContract() async throws {
    let width = 8
    let height = 2
    let expected = identityPattern(width: width, height: height)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-native-exr-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("ScreenSimulation-00000012.exr")
    try NativeOutputRenderer.encodeEXR(expected, width: width, height: height)
        .write(to: url, options: .atomic)
    let exrBytes = try Data(contentsOf: url)
    let chunkTable = try firstEXRChunkOffset(in: exrBytes)
    #expect(chunkTable.offset >= UInt64(chunkTable.minimumOffset))
    #expect(chunkTable.offset < UInt64(exrBytes.count))
    let actual = try await NativeMediaDecoder.decode(url: url, time: .zero).rgba
    #expect(actual.count == expected.count)
    #expect(zip(actual, expected).map { abs($0 - $1) }.max() ?? 0 <= 0.001)
}

@Test @MainActor func separatedDeviceSpillUsesComplementaryBoundedContributions() throws {
    // Canonical Delivery Raster RGB is premultiplied physical contribution.
    let source: [Float] = [
        0.3, -0.1, 1.2, 0,
        0.1, 0.2, 0.3, 0.5,
        0.7, 0.8, 0.9, 1,
    ]
    let passes = try NativeOutputRenderer.editorialDeviceSpillPasses(source)
    for pixel in 0 ..< 3 {
        let offset = pixel * 4
        let alpha = source[offset + 3]
        for channel in 0 ..< 3 {
            let reconstructed = passes.device[offset + channel] * alpha
                + passes.spill[offset + channel]
            #expect(abs(reconstructed - source[offset + channel]) < 0.000_001)
        }
        #expect(passes.device[offset + 3] == alpha)
        #expect(passes.spill[offset + 3] == 1)
    }
    #expect(passes.device[0] == 0.3)
    #expect(passes.spill[0] == 0.3)
    #expect(passes.device[4] == 0.1)
    #expect(passes.spill[4] == 0.05)
    // A very small matte never creates the unbounded RGB/alpha values that
    // previously clipped at the ProRes boundary and produced a dark contour.
    let edge = try NativeOutputRenderer.editorialDeviceSpillPasses([
        0.2, 0.4, 0.8, 0.000_1,
    ])
    #expect(edge.device[0] == 0.2)
    #expect(edge.spill[0] > 0.199)
}

@Test @MainActor func editorialACEScctSpillSubtractsBlackAndReconstructsOverBlack() throws {
    let black = SIMD3<Float>(0.08, 0.08, 0.08)
    let carrier: [Float] = [
        0.20, 0.40, 0.90, 0,
        0.30, 0.50, 0.70, 0.5,
        0.60, 0.80, 1.00, 1,
    ]
    let spill = try NativeOutputRenderer.editorialACEScctAddSpill(
        encodedCarrier: carrier, encodedBlack: black
    )
    #expect(spill.allSatisfy { $0.isFinite })
    for pixel in 0 ..< 3 {
        let offset = pixel * 4
        let matte = carrier[offset + 3]
        for channel in 0 ..< 3 {
            let expected = (1 - matte) * (carrier[offset + channel] - black[channel])
            #expect(abs(spill[offset + channel] - expected) < 0.000_001)
            let overBlack = carrier[offset + channel] * matte + black[channel] * (1 - matte)
            #expect(abs(overBlack + spill[offset + channel] - carrier[offset + channel]) < 0.000_001)
        }
        #expect(spill[offset + 3] == 1)
    }
    #expect(spill[0] > 0) // encoded RGB survives where matte is zero
    #expect(spill[8] == 0)
    #expect(spill[9] == 0)
    #expect(spill[10] == 0)
}

@Test @MainActor func editorialDeviceSpillMoviePreservesExteriorRGBAndUsesOneFrameRequest() async throws {
    let display = try StudioColorMetalDisplay()
    let width = 8, height = 2
    var rgba = [Float](repeating: 0, count: width * height * 4)
    for pixel in 0 ..< width * height {
        let offset = pixel * 4
        rgba[offset] = 0.18 + Float(pixel) * 0.01
        rgba[offset + 1] = 0.36
        rgba[offset + 2] = 0.72
        rgba[offset + 3] = [Float(0), 0.5, 1][pixel % 3]
    }
    let frame = try independentLinearFrame(width: width, height: height, rgba: rgba)
    let preset = StudioRenderPreset.builtIns[9]
    let configuration = renderConfiguration(
        format: .proRes4444XQ, preset: preset, alpha: .straight,
        signalRange: .full, frameRange: 0 ... 0,
        composition: .deviceAndSpillSeparate,
        outputType: .editorial,
        spillDeliveryMode: .editorialACEScctAdd,
        motionBlurMode: .approximate2D
    )
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("editorial-spill-movie-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let plan = try RenderOutputPlan.prepare(
        configuration: configuration, selectedDestination: root
    )
    var requestedFrames: [Int] = []
    _ = try await NativeOutputRenderer.render(
        configuration: configuration, outputPlan: plan, audioSource: nil,
        display: display,
        frameProvider: { index in
            requestedFrames.append(index)
            return frame
        },
        progress: { _, _ in }
    )
    #expect(requestedFrames == [0])
    let device = try await decodeFirstProResARGB16(
        plan.destination.appendingPathComponent("ScreenSimulation_Device.mov")
    )
    let spill = try await decodeFirstProResARGB16(
        plan.destination.appendingPathComponent("ScreenSimulation_Spill.mov")
    )
    #expect(device[3] < 0.002)
    #expect(device[0] > 0.1)
    #expect(spill[0] > 0.01)
    for offset in stride(from: 3, to: spill.count, by: 4) {
        #expect(spill[offset] > 0.998)
    }
}

@Test @MainActor func approximate2DMotionBlurFiltersCarrierAndMatteBeforeSeparation() throws {
    let source: [Float] = [
        0.8, -0.2, 1.4, 0,
        0.4, 0.2, 0.1, 0.5,
        1.0, 0.6, 0.3, 1,
        0.2, 0.1, 0.9, 0.5,
        0.7, 0.3, 0.2, 0,
    ]
    let identity = try Approximate2DMotionBlur.apply(
        to: source, width: 5, height: 1,
        shutterStart: .zero, shutterEnd: .zero, samples: 8
    )
    #expect(identity == source)
    let phased = try Approximate2DMotionBlur.apply(
        to: source, width: 5, height: 1,
        shutterStart: CGPoint(x: 1, y: 0),
        shutterEnd: CGPoint(x: 1, y: 0), samples: 2
    )
    #expect(phased != source)
    #expect(phased[8] == source[4])

    let blurred = try Approximate2DMotionBlur.apply(
        to: source, width: 5, height: 1,
        shutterStart: CGPoint(x: -2, y: 0),
        shutterEnd: CGPoint(x: 2, y: 0), samples: 8
    )
    #expect(blurred != source)
    #expect(blurred.allSatisfy { $0.isFinite })
    #expect(blurred[0] != 0) // additive RGB survives independently of zero matte
    let passes = try NativeOutputRenderer.editorialDeviceSpillPasses(blurred)
    for pixel in 0 ..< 5 {
        let offset = pixel * 4
        let matte = blurred[offset + 3]
        #expect((0 ... 1).contains(matte))
        for channel in 0 ..< 3 {
            let reconstruction = passes.device[offset + channel] * matte
                + passes.spill[offset + channel]
            #expect(abs(reconstruction - blurred[offset + channel]) < 0.000_001)
        }
    }
}

@Test func approximate2DMotionVelocitySamplingNeverRequestsANegativeFrame() throws {
    let first = try Approximate2DMotionVelocitySampling.resolve(frame: 0)
    #expect(first.earlierTimeFrame == -1)
    #expect(first.earlierIdentityFrame == 0)
    #expect(first.laterTimeFrame == 1)
    #expect(first.laterIdentityFrame == 1)
    let beforeFirst = try PhysicalFrameSelection(
        frameIndex: Int64(first.earlierIdentityFrame),
        timeNumerator: Int64(first.earlierTimeFrame), timeDenominator: 24,
        frameRateNumerator: 24, frameRateDenominator: 1
    )
    #expect(beforeFirst.frameIndex == 0)
    #expect(beforeFirst.timeNumerator == -1)

    let interior = try Approximate2DMotionVelocitySampling.resolve(frame: 12)
    #expect(interior.earlierTimeFrame == 11)
    #expect(interior.earlierIdentityFrame == 11)
    #expect(interior.laterTimeFrame == 13)
    #expect(interior.laterIdentityFrame == 13)

    #expect(throws: PhysicalContractError.invalidFrameIndex) {
        try Approximate2DMotionVelocitySampling.resolve(frame: -1)
    }
}

@Test @MainActor func separatedVfxProResRetainsDeviceAlphaAndNonBlackSpill() async throws {
    let display = try StudioColorMetalDisplay()
    let width = 32, height = 18
    var rgba = [Float](repeating: 0, count: width * height * 4)
    for y in 0 ..< height {
        for x in 0 ..< width {
            let offset = (y * width + x) * 4
            let alpha = Float(x) / Float(width - 1)
            rgba[offset] = 0.3 * alpha
            rgba[offset + 1] = Float(y + 1) / Float(height) * alpha
            rgba[offset + 2] = 0.8 * alpha
            rgba[offset + 3] = alpha
        }
    }
    // Preserve one genuine additive zero-matte sample for the Spill pass.
    rgba[0] = 0.2
    rgba[1] = 0.1
    rgba[2] = 0.05
    // A halo contribution crossing a nearly transparent Device edge used to be
    // divided by this matte and clipped in the Device movie while Spill became black.
    rgba[4] = 0.2
    rgba[5] = 0.1
    rgba[6] = 0.05
    rgba[7] = 0.000_1
    let input = try #require(StudioColorInputTransform.catalog.first { $0.id == "acescg" })
    let frame = try display.makeACEScgFrame(
        width: width, height: height, encodedRGBA: rgba,
        input: input, alpha: .premultiplied
    )
    let preset = StudioRenderPreset.builtIns[9]
    let configuration = renderConfiguration(
        format: preset.format, preset: preset, alpha: .straight,
        signalRange: .full, frameRange: 0 ... 1,
        composition: .deviceAndSpillSeparate
    )
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("separate-vfx-prores-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let plan = try RenderOutputPlan.prepare(
        configuration: configuration, selectedDestination: root
    )
    var requestedFrames: [Int] = []
    _ = try await NativeOutputRenderer.render(
        configuration: configuration, outputPlan: plan,
        audioSource: nil, display: display,
        frameProvider: { index in
            requestedFrames.append(index)
            return frame
        }, progress: { _, _ in }
    )
    #expect(requestedFrames == [0, 1])

    let device = try await decodeFirstProResARGB16(
        plan.destination.appendingPathComponent("ScreenSimulation_Device.mov")
    )
    let spill = try await decodeFirstProResARGB16(
        plan.destination.appendingPathComponent("ScreenSimulation_Spill.mov")
    )
    let deviceAlpha = stride(from: 3, to: device.count, by: 4).map { device[$0] }
    #expect((deviceAlpha.min() ?? 1) < 0.05)
    #expect((deviceAlpha.max() ?? 0) > 0.95)
    #expect(device[4] < 0.7)
    #expect(spill[4] > 0.3)
    #expect(stride(from: 0, to: spill.count, by: 4).contains {
        spill[$0] > 0.01 || spill[$0 + 1] > 0.01 || spill[$0 + 2] > 0.01
    })
    // Fractional-alpha pixels carry a smooth non-black complementary Spill;
    // the pass is no longer forced to ACEScct black until alpha reaches zero.
    #expect(stride(from: 4, to: spill.count, by: 4).contains {
        spill[$0] > 0.11 || spill[$0 + 1] > 0.11 || spill[$0 + 2] > 0.11
    })
}

@Test func separatedDeviceSpillPlanOwnsBothMovieAndSequenceManifests() throws {
    let root = FileManager.default.temporaryDirectory
    let movie = renderConfiguration(
        format: .proRes4444, preset: StudioRenderPreset.builtIns[0],
        alpha: .straight, signalRange: .video, frameRange: 1 ... 2,
        composition: .deviceAndSpillSeparate
    )
    let moviePlan = try RenderOutputPlan.prepare(configuration: movie, selectedDestination: root)
    #expect(moviePlan.kind == .deviceSpillDelivery)
    #expect(moviePlan.generatedRelativePaths == [
        "ScreenSimulation_Device.mov", "ScreenSimulation_Spill.mov",
    ])

    let sequence = renderConfiguration(
        format: .openEXR, preset: StudioRenderPreset.builtIns[5],
        alpha: .straight, signalRange: .full, frameRange: 7 ... 8,
        composition: .deviceAndSpillSeparate
    )
    let sequencePlan = try RenderOutputPlan.prepare(
        configuration: sequence, selectedDestination: root
    )
    #expect(sequencePlan.generatedRelativePaths == [
        "ScreenSimulation_Device.00000007.exr", "ScreenSimulation_Spill.00000007.exr",
        "ScreenSimulation_Device.00000008.exr", "ScreenSimulation_Spill.00000008.exr",
    ])
}

private enum EXRChunkTableInspectionError: Error {
    case malformedHeader
}

private func firstEXRChunkOffset(in data: Data) throws -> (offset: UInt64, minimumOffset: Int) {
    guard data.count >= 8, Array(data.prefix(4)) == [0x76, 0x2f, 0x31, 0x01] else {
        throw EXRChunkTableInspectionError.malformedHeader
    }
    var cursor = 8
    func skipNullTerminatedString() throws {
        guard let terminator = data[cursor...].firstIndex(of: 0) else {
            throw EXRChunkTableInspectionError.malformedHeader
        }
        cursor = terminator + 1
    }
    while cursor < data.count, data[cursor] != 0 {
        try skipNullTerminatedString()
        try skipNullTerminatedString()
        guard cursor + 4 <= data.count else {
            throw EXRChunkTableInspectionError.malformedHeader
        }
        let attributeSize = (0 ..< 4).reduce(0) {
            $0 | Int(data[cursor + $1]) << ($1 * 8)
        }
        cursor += 4
        guard attributeSize >= 0, cursor + attributeSize < data.count else {
            throw EXRChunkTableInspectionError.malformedHeader
        }
        cursor += attributeSize
    }
    cursor += 1
    let minimumOffset = cursor + 8
    guard minimumOffset <= data.count else {
        throw EXRChunkTableInspectionError.malformedHeader
    }
    let offset = (0 ..< 8).reduce(UInt64(0)) {
        $0 | UInt64(data[cursor + $1]) << UInt64($1 * 8)
    }
    return (offset, minimumOffset)
}

@Test @MainActor func proRes4444RoundtripPreservesFramesMetadataAndAlpha() async throws {
    for alpha in [StudioColorAlphaAssociation.straight, .premultiplied] {
        let result = try await movieRoundtrip(format: .proRes4444, alpha: alpha)
        #expect(result.detection.proposedInputTransformID == "input-rec709")
        #expect(result.detection.hasAlpha)
        #expect(result.detection.alpha == (alpha == .straight ? .straight : .premultiplied))
        #expect(result.exactFrameRate == .fps24)
        #expect(result.frameCount == 3)
        #expect(result.maximumError <= 0.026, "ProRes \(alpha.rawValue) max \(result.maximumError)")
        #expect(result.rootMeanSquareError <= 0.003, "ProRes \(alpha.rawValue) RMSE \(result.rootMeanSquareError)")
        print("PRORES alpha=\(alpha.rawValue) max=\(result.maximumError) rmse=\(result.rootMeanSquareError)")
    }
}

@Test @MainActor func proRes4444HDRPortraitEncodesMoreThanTwoFrames() async throws {
    let display = try StudioColorMetalDisplay()
    let width = 1_000
    let height = 1_500
    let input = try #require(
        StudioColorInputTransform.catalog.first { $0.id == "acescg" }
    )
    let values = [Float](repeating: 0.18, count: width * height * 4)
        .enumerated().map { $0.offset % 4 == 3 ? 1 : $0.element }
    let frame = try display.makeACEScgFrame(
        width: width, height: height, encodedRGBA: values,
        input: input, alpha: .straight
    )
    let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-native-prores-hdr-\(UUID().uuidString).mov")
    let url = try await NativeOutputRenderer.render(
        configuration: renderConfiguration(
            format: .proRes4444, preset: StudioRenderPreset.builtIns[1],
            alpha: .straight, signalRange: .video, frameRange: 0 ... 2
        ),
        destination: destination, audioSource: nil,
        display: display, frameProvider: { _ in frame }, progress: { _, _ in }
    )
    let timeline = try NativeFFmpegMedia.probe(url: url)
    #expect(timeline.frameCount == 3)
}

@Test @MainActor func vfxProResDoesNotMasqueradeAsARec709Master() async throws {
    let display = try StudioColorMetalDisplay()
    let frame = try display.makeACEScgFrame(
        width: 32,
        height: 18,
        encodedRGBA: [Float](repeating: 0.18, count: 32 * 18 * 4)
            .enumerated().map { $0.offset % 4 == 3 ? 1 : $0.element },
        input: try #require(StudioColorInputTransform.catalog.first { $0.id == "acescg" }),
        alpha: .straight
    )
    let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("vfx-log-\(UUID().uuidString).mov")
    _ = try await NativeOutputRenderer.render(
        configuration: renderConfiguration(
            format: .proRes4444XQ,
            preset: StudioRenderPreset.builtIns[8],
            alpha: .straight,
            signalRange: .video,
            frameRange: 0 ... 0
        ),
        destination: destination,
        audioSource: nil,
        display: display,
        frameProvider: { _ in frame },
        progress: { _, _ in }
    )
    let detection = await StudioMediaMetadataDetector.detect(
        url: destination,
        isVideo: true
    )
    #expect(detection.proposedInputTransformID == nil)
}

@Test @MainActor func vfxEditorialACEScctFullStraightRoundtripComposesVisually() async throws {
    let display = try StudioColorMetalDisplay()
    let width = 96, height = 54
    var rgba = [Float](repeating: 0, count: width * height * 4)
    for y in 0 ..< height {
        for x in 0 ..< width {
            let offset = (y * width + x) * 4
            let alpha = Float(x) / Float(width - 1)
            let intensity: Float = y < height / 3 ? 0.18 : (y < 2 * height / 3 ? 8 : 64)
            rgba[offset] = intensity
            rgba[offset + 1] = intensity * Float(x % 3 == 0 ? 0.25 : 1)
            rgba[offset + 2] = intensity * Float(x % 3 == 2 ? 1 : 0.125)
            rgba[offset + 3] = alpha
        }
    }
    let acescg = try #require(StudioColorInputTransform.catalog.first { $0.id == "acescg" })
    let expectedFrame = try independentLinearFrame(width: width, height: height, rgba: rgba)
    let expected = try display.readLinearRGBA(expectedFrame)
    let preset = StudioRenderPreset.builtIns[9]
    let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("vfx-editorial-\(UUID().uuidString).mov")
    defer { try? FileManager.default.removeItem(at: destination) }
    _ = try await NativeOutputRenderer.render(
        configuration: renderConfiguration(
            format: preset.format, preset: preset, alpha: .straight,
            signalRange: .full, frameRange: 0 ... 0
        ),
        destination: destination, audioSource: nil,
        display: display, frameProvider: { _ in expectedFrame }, progress: { _, _ in }
    )
    let detection = await StudioMediaMetadataDetector.detect(url: destination, isVideo: true)
    #expect(detection.proposedInputTransformID == nil)
    #expect(detection.hasAlpha)
    #expect(detection.alpha == .straight)
    // Apple defines the selected high-bit-depth source format as RGB, where code values are
    // inherently full range; the ProRes sample description has no Y′CbCr range flag.
    #expect(detection.range == nil)

    let acescct = try #require(StudioColorInputTransform.catalog.first { $0.id == "acescct" })
    let decodedEncoded = try await decodeFirstProResARGB16(destination)
    let decodedAlpha = stride(from: 3, to: decodedEncoded.count, by: 4).map {
        decodedEncoded[$0]
    }
    var decodedRGB = decodedEncoded
    for offset in stride(from: 3, to: decodedRGB.count, by: 4) {
        decodedRGB[offset] = 1
    }
    let decodedFrame = try display.makeACEScgFrame(
        width: width, height: height, encodedRGBA: decodedRGB,
        input: acescct, alpha: .ignore
    )
    var decoded = try display.readLinearRGBA(decodedFrame)
    for (pixel, alpha) in decodedAlpha.enumerated() {
        decoded[pixel * 4 + 3] = alpha
    }
    #expect(expected[3] == 0)
    #expect(expected[0] > 0.1)
    #expect(decoded[3] <= 0.002)
    #expect(decoded[0] > 0.1)
    for offset in stride(from: 0, to: decoded.count, by: 4) {
        let alpha = decoded[offset + 3]
        for channel in 0 ..< 3 {
            let device = decoded[offset + channel] * alpha
            let spill = decoded[offset + channel] * (1 - alpha)
            #expect(abs(device + spill - decoded[offset + channel]) < 0.000_01)
        }
    }
    var alphaMaximum: Float = 0
    for offset in stride(from: 3, to: expected.count, by: 4) {
        alphaMaximum = max(alphaMaximum, abs(expected[offset] - decoded[offset]))
    }
    #expect(alphaMaximum <= 0.002)

    let viewer = try #require(StudioColorOutputTransform.catalog.first {
        $0.id == "aces2-srgb-sdr-100"
    })
    var maximumDisplayDifference = 0
    var squaredDisplayDifference: Double = 0
    var displaySampleCount = 0
    for background: Float in [0, 0.18, 1] {
        func composite(_ values: [Float]) -> [Float] {
            var result = values
            for offset in stride(from: 0, to: result.count, by: 4) {
                let alpha = result[offset + 3]
                result[offset] += background * (1 - alpha)
                result[offset + 1] += background * (1 - alpha)
                result[offset + 2] += background * (1 - alpha)
                result[offset + 3] = 1
            }
            return result
        }
        let expectedComposite = try display.makeACEScgFrame(
            width: width, height: height, encodedRGBA: composite(expected),
            input: acescg, alpha: .straight
        )
        let decodedComposite = try display.makeACEScgFrame(
            width: width, height: height, encodedRGBA: composite(decoded),
            input: acescg, alpha: .straight
        )
        for (lhs, rhs) in zip(
            try display.renderRGBA8(expectedComposite, output: viewer),
            try display.renderRGBA8(decodedComposite, output: viewer)
        ) {
            let difference = abs(Int(lhs) - Int(rhs))
            maximumDisplayDifference = max(maximumDisplayDifference, difference)
            squaredDisplayDifference += Double(difference * difference)
            displaySampleCount += 1
        }
    }
    let displayRMSE = sqrt(squaredDisplayDifference / Double(displaySampleCount))
    // ProRes RGB is visually, not mathematically, lossless. This operational saturated
    // envelope must remain within a small display-code difference after three backgrounds;
    // the separate stress pattern deliberately retains harder primaries for inspection.
    #expect(maximumDisplayDifference <= 16)
    #expect(displayRMSE <= 3)
}

private func decodeFirstProResARGB16(_ url: URL) async throws -> [Float] {
    let asset = AVURLAsset(url: url)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let track = try #require(tracks.first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_64ARGB,
        ]
    )
    #expect(reader.canAdd(output))
    reader.add(output)
    #expect(reader.startReading())
    let sample = try #require(output.copyNextSampleBuffer())
    let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
    let base = try #require(CVPixelBufferGetBaseAddress(buffer))
    var rgba = [Float](repeating: 0, count: width * height * 4)
    for y in 0 ..< height {
        let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt16.self)
        for x in 0 ..< width {
            let source = x * 4
            let destination = (y * width + x) * 4
            rgba[destination] = Float(UInt16(bigEndian: row[source + 1])) / 65_535
            rgba[destination + 1] = Float(UInt16(bigEndian: row[source + 2])) / 65_535
            rgba[destination + 2] = Float(UInt16(bigEndian: row[source + 3])) / 65_535
            rgba[destination + 3] = Float(UInt16(bigEndian: row[source])) / 65_535
        }
    }
    return rgba
}

@Test @MainActor func h264RoundtripSeparatesCodecLossFromColorContract() async throws {
    for range in [StudioSignalRange.video, .full] {
        let result = try await movieRoundtrip(
            format: .h264High, alpha: .ignore, signalRange: range
        )
        #expect(result.detection.proposedInputTransformID == "input-rec709")
        #expect(!result.detection.hasAlpha)
        #expect(result.detection.matrix == .bt709)
        #expect(result.detection.range == range)
        #expect(result.exactFrameRate == .fps24)
        #expect(result.frameCount == 3)
        #expect(result.maximumError <= 0.20, "H.264 \(range.rawValue) max \(result.maximumError)")
        #expect(result.rootMeanSquareError <= 0.055,
                "H.264 \(range.rawValue) RMSE \(result.rootMeanSquareError)")
        let neutralTolerance: Float = range == .video ? 0.012 : 0.015
        #expect(result.neutralRootMeanSquareError <= neutralTolerance,
                "H.264 \(range.rawValue) neutral/color-path RMSE \(result.neutralRootMeanSquareError)")
        print("H264 range=\(range.rawValue) max=\(result.maximumError) rmse=\(result.rootMeanSquareError) neutral_rmse=\(result.neutralRootMeanSquareError)")
    }
}

@Test @MainActor func movieOutputPreservesFractionalCadenceExactly() async throws {
    let frameRate = try StudioFrameRate(numerator: 24_000, denominator: 1_001)
    let result = try await movieRoundtrip(
        format: .h264High,
        alpha: .ignore,
        signalRange: .video,
        frameRate: frameRate
    )
    #expect(result.exactFrameRate == frameRate)
    #expect(result.frameCount == 3)
}

@Test @MainActor func h265HDRWritesExplicitPQMatrixAndRange() async throws {
    let display = try StudioColorMetalDisplay()
    let width = 96
    let height = 54
    let frame = try display.makeACEScgFrame(
        width: width,
        height: height,
        encodedRGBA: moviePattern(
            width: width, height: height, frameIndex: 0,
            includeAlpha: false, premultipliedInput: false
        ),
        input: StudioColorInputTransform.catalog.first { $0.id == "acescg" }!,
        alpha: .ignore
    )
    for range in [StudioSignalRange.video, .full] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("screen-native-h265-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = try await NativeOutputRenderer.render(
            configuration: renderConfiguration(
                format: .h265High, preset: StudioRenderPreset.builtIns[1],
                alpha: .ignore, signalRange: range, frameRange: 0 ... 0
            ),
            destination: root.appendingPathComponent("pq.mov"),
            audioSource: nil,
            display: display,
            frameProvider: { _ in frame },
            progress: { _, _ in }
        )
        let detection = await StudioMediaMetadataDetector.detect(url: url, isVideo: true)
        #expect(detection.proposedInputTransformID == "display-rec2100-pq-dcm")
        #expect(detection.inputTransformProvenance == .detected)
        #expect(detection.matrix == .bt2020)
        #expect(detection.range == range)
    }
}

private struct MovieRoundtripResult {
    let detection: StudioMediaDetection
    let exactFrameRate: StudioFrameRate
    let frameCount: Int
    let maximumError: Float
    let rootMeanSquareError: Float
    let neutralRootMeanSquareError: Float
}

@MainActor
private func movieRoundtrip(
    format: StudioOutputFormat,
    alpha: StudioColorAlphaAssociation,
    signalRange: StudioSignalRange? = nil,
    frameRate: StudioFrameRate = .fps24
) async throws -> MovieRoundtripResult {
    let display = try StudioColorMetalDisplay()
    let width = 96
    let height = 54
    let input = StudioColorInputTransform.catalog.first { $0.id == "acescg" }!
    var expected: [[Float]] = []
    var frames: [StudioColorMetalFrame] = []
    for frameIndex in 0 ..< 3 {
        let values = moviePattern(
            width: width, height: height, frameIndex: frameIndex,
            includeAlpha: alpha != .ignore,
            premultipliedInput: alpha == .premultiplied
        )
        let frame = try display.makeACEScgFrame(
            width: width, height: height, encodedRGBA: values,
            input: input, alpha: alpha
        )
        frames.append(frame)
        expected.append(try display.readLinearRGBA(frame))
    }
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-native-movie-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let destination = root.appendingPathComponent("roundtrip.\(format.fileExtension)")
    let url = try await NativeOutputRenderer.render(
        configuration: renderConfiguration(
            format: format, preset: StudioRenderPreset.builtIns[0],
            alpha: alpha,
            signalRange: signalRange ?? (
                format == .h264High || format == .proRes4444 ? .video : .full
            ),
            frameRate: frameRate,
            frameRange: 0 ... 2
        ),
        destination: destination, audioSource: nil,
        display: display, frameProvider: { frames[$0] }, progress: { _, _ in }
    )
    let detection = await StudioMediaMetadataDetector.detect(url: url, isVideo: true)
    let session = NativeMediaSession()
    let info = try await session.openVideo(
        url,
        hasAlpha: detection.hasAlpha,
        colorModel: .ycbcr,
        matrix: .bt709,
        decodedRange: .video
    )
    let inverse = StudioColorInputTransform.catalog.first {
        $0.id == "display-rec709-aces2-sdr"
    }!
    var squaredError: Double = 0
    var sampleCount = 0
    var neutralSquaredError: Double = 0
    var neutralSampleCount = 0
    var maximumError: Float = 0
    for frameIndex in 0 ..< 3 {
        let time = CMTime(
            value: CMTimeValue(frameIndex) * CMTimeValue(frameRate.denominator),
            timescale: CMTimeScale(frameRate.numerator)
        )
        let sample = try #require(try await session.exactSample(at: time))
        let decoded = try display.makeACEScgFrame(
            pixelBuffer: sample.pixelBuffer, input: inverse,
            alpha: alpha, matrix: .bt709, range: detection.range == .full ? .full : .video
        )
        let actual = try display.readLinearRGBA(decoded)
        for (offset, pair) in zip(actual, expected[frameIndex]).enumerated() {
            let (actualValue, expectedValue) = pair
            let error = abs(actualValue - expectedValue)
            maximumError = max(maximumError, error)
            squaredError += Double(error * error)
            sampleCount += 1
            let pixel = offset / 4
            if pixel / width < height / 2, offset % 4 != 3 {
                neutralSquaredError += Double(error * error)
                neutralSampleCount += 1
            }
        }
    }
    return MovieRoundtripResult(
        detection: detection,
        exactFrameRate: info.exactFrameRate,
        frameCount: info.frameCount,
        maximumError: maximumError,
        rootMeanSquareError: Float(sqrt(squaredError / Double(sampleCount))),
        neutralRootMeanSquareError: Float(sqrt(neutralSquaredError / Double(neutralSampleCount)))
    )
}

private func moviePattern(
    width: Int,
    height: Int,
    frameIndex: Int,
    includeAlpha: Bool,
    premultipliedInput: Bool
) -> [Float] {
    (0 ..< width * height).flatMap { index -> [Float] in
        let x = index % width
        let y = index / width
        let ramp = Float(x) / Float(width - 1)
        let checker = Float(((x / 2) + (y / 2) + frameIndex) % 2)
        let patch = Float((x / 12 + frameIndex) % 6) / 5
        let alpha: Float = includeAlpha ? Float(y) / Float(height - 1) : 1
        var rgb = y < height / 2
            ? SIMD3<Float>(repeating: 0.01 + 0.28 * ramp)
            : SIMD3<Float>(
                0.01 + 0.28 * ramp,
                0.015 + 0.24 * patch,
                0.02 + 0.20 * checker
            )
        if premultipliedInput { rgb *= alpha }
        return [rgb.x, rgb.y, rgb.z, alpha]
    }
}

private func identityPattern(width: Int, height: Int) -> [Float] {
    (0 ..< width * height).flatMap { index -> [Float] in
        let position = Float(index) / Float(max(1, width * height - 1))
        let alpha: Float = index % 5 == 0 ? 0 : position
        return [
            -0.25 + position * 2.5,
            position * 0.5,
            4 - position * 3,
            alpha,
        ]
    }
}

@Test @MainActor func suppliedGoldenMovieRoundtrip() async throws {
    guard let path = ProcessInfo.processInfo.environment["SCREEN_GOLDEN_SOURCE"] else { return }
    let sourceURL = URL(fileURLWithPath: path)
    let detection = await StudioMediaMetadataDetector.detect(url: sourceURL, isVideo: true)
    let sourceSession = NativeMediaSession()
    let colorModel = try #require(detection.colorModel)
    let detectedRange = try #require(detection.range)
    let sourceInfo = try await sourceSession.openVideo(
        sourceURL,
        hasAlpha: detection.hasAlpha,
        colorModel: colorModel,
        matrix: .bt709,
        decodedRange: detectedRange
    )
    let display = try StudioColorMetalDisplay()
    let proposedInputTransformID = try #require(detection.proposedInputTransformID)
    let input = try #require(StudioColorInputTransform.catalog.first {
        $0.id == proposedInputTransformID
    })
    let detectedAlpha = try #require(detection.alpha)
    let alpha: StudioColorAlphaAssociation = switch detectedAlpha {
    case .premultiplied: .premultiplied
    case .ignore: .ignore
    case .straight: .straight
    }
    let detectedMatrix = try #require(detection.matrix)
    let matrix: StudioColorSignalMatrix = switch detectedMatrix {
    case .bt601: .bt601
    case .bt709: .bt709
    case .bt2020: .bt2020
    }
    let range: StudioColorSignalRange = detectedRange == .video ? .video : .full
    let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("golden-\(UUID().uuidString).mov")
    let playbackP95 = try await sequentialPlaybackP95(
        sourceURL: sourceURL, display: display, input: input,
        alpha: alpha, matrix: matrix, range: range
    )
    let renderedURL = try await NativeOutputRenderer.render(
        configuration: renderConfiguration(
            format: .proRes4444, preset: StudioRenderPreset.builtIns[0],
            alpha: alpha, signalRange: .video,
            frameRate: sourceInfo.exactFrameRate,
            frameRange: 0 ... max(0, sourceInfo.frameCount - 1)
        ),
        destination: outputURL, audioSource: nil, display: display,
        frameProvider: { frameIndex in
            let time = CMTime(
                value: CMTimeValue(frameIndex)
                    * CMTimeValue(sourceInfo.exactFrameRate.denominator),
                timescale: CMTimeScale(sourceInfo.exactFrameRate.numerator)
            )
            let sample = try #require(try await sourceSession.exactSample(at: time))
            let frame = try display.makeACEScgFrame(
                pixelBuffer: sample.pixelBuffer, input: input, alpha: alpha,
                matrix: matrix, range: range
            )
            return frame
        },
        progress: { _, _ in }
    )
    let outputDetection = await StudioMediaMetadataDetector.detect(url: renderedURL, isVideo: true)
    let outputSession = NativeMediaSession()
    let outputInfo = try await outputSession.openVideo(
        renderedURL,
        hasAlpha: outputDetection.hasAlpha,
        colorModel: try #require(outputDetection.colorModel),
        matrix: try #require(outputDetection.matrix),
        decodedRange: try #require(outputDetection.range)
    )
    var maximum: Float = 0
    var squared: Double = 0
    var count = 0
    var displayMaximum = 0
    var displaySquared: Double = 0
    var displayCount = 0
    let roundtripDisplay = StudioColorOutputTransform.catalog.first {
        $0.id == "aces2-rec709-sdr-100"
    }!
    for frameIndex in 0 ..< sourceInfo.frameCount {
        let time = CMTime(
            value: CMTimeValue(frameIndex),
            timescale: CMTimeScale(sourceInfo.frameRate.rounded())
        )
        let sourceSample = try #require(try await sourceSession.exactSample(at: time))
        let outputSample = try #require(try await outputSession.exactSample(at: time))
        let sourceFrame = try display.makeACEScgFrame(
            pixelBuffer: sourceSample.pixelBuffer, input: input, alpha: alpha,
            matrix: matrix, range: range
        )
        let outputFrame = try display.makeACEScgFrame(
            pixelBuffer: outputSample.pixelBuffer, input: input, alpha: alpha,
            matrix: matrix, range: range
        )
        let sourceValues = try display.readLinearRGBA(sourceFrame)
        let outputValues = try display.readLinearRGBA(outputFrame)
        for (lhs, rhs) in zip(sourceValues, outputValues) {
            let error = abs(lhs - rhs)
            maximum = max(maximum, error)
            squared += Double(error * error)
            count += 1
        }
        let sourceDisplay = try display.renderRGBA8(sourceFrame, output: roundtripDisplay)
        let outputDisplay = try display.renderRGBA8(outputFrame, output: roundtripDisplay)
        for (lhs, rhs) in zip(sourceDisplay, outputDisplay) {
            let error = abs(Int(lhs) - Int(rhs))
            displayMaximum = max(displayMaximum, error)
            displaySquared += Double(error * error)
            displayCount += 1
        }
    }
    let rmse = sqrt(squared / Double(count))
    let displayRMSE = sqrt(displaySquared / Double(displayCount))
    let sourceModel = detection.colorModel?.rawValue ?? "unknown"
    let sourceRange = detection.range?.rawValue ?? "unknown"
    let sourceMatrix = detection.matrix?.rawValue ?? "unknown"
    let inputProvenance = detection.inputTransformProvenance?.rawValue ?? "none"
    let outputModel = outputDetection.colorModel?.rawValue ?? "unknown"
    let outputRange = outputDetection.range?.rawValue ?? "unknown"
    print("GOLDEN source=\(sourceURL.lastPathComponent) frames=\(sourceInfo.frameCount) fps=\(sourceInfo.frameRate) source_model=\(sourceModel) source_range=\(sourceRange) source_matrix=\(sourceMatrix) input_provenance=\(inputProvenance) output_model=\(outputModel) output_range=\(outputRange) linear_max=\(maximum) linear_rmse=\(rmse) display_max_code=\(displayMaximum) display_rmse_code=\(displayRMSE) sequential_decode_aces_preview_p95_ms=\(playbackP95) output=\(renderedURL.path)")
    #expect(outputInfo.frameCount == sourceInfo.frameCount)
    #expect(abs(outputInfo.frameRate - sourceInfo.frameRate) < 0.01)
    #expect(outputDetection.proposedInputTransformID == "input-rec709")
    #expect(displayMaximum <= 5)
    #expect(displayRMSE <= 1)
}

private func renderConfiguration(
    format: StudioOutputFormat,
    preset: StudioRenderPreset,
    alpha: StudioColorAlphaAssociation,
    signalRange: StudioSignalRange,
    frameRate: StudioFrameRate = .fps24,
    frameRange: ClosedRange<Int>,
    composition: StudioRenderComposition = .deviceAndSpillTogether,
    outputType: StudioOutputType = .standard,
    spillDeliveryMode: StudioSpillDeliveryMode = .physicalLinear,
    motionBlurMode: StudioRenderMotionBlurMode = .disabled
) -> StudioResolvedRenderConfiguration {
    let alphaMode: StudioAlphaMode = switch alpha {
    case .straight: .straight
    case .premultiplied: .premultiplied
    case .ignore: .ignore
    }
    return StudioResolvedRenderConfiguration(
        outputType: outputType,
        jobName: "ScreenSimulation",
        overwritePolicy: .failIfExists,
        fusionScene: nil,
        composition: composition,
        spillDeliveryMode: spillDeliveryMode,
        motionBlurMode: motionBlurMode,
        motionSamples: 8,
        format: format,
        pipeline: preset.pipeline,
        target: preset.target,
        peakNits: preset.peakNits,
        display: preset.display,
        view: preset.view,
        vfxInterchangeEncodingID: preset.target == .vfxLog
            ? (preset.fixedVFXInterchangeEncodingID ?? "arri-logc4-awg4") : nil,
        pixelEncoding: preset.fixedVFXInterchangeEncodingID == nil
            ? format.defaultPixelEncoding : preset.pixelEncoding,
        signalRange: signalRange,
        alpha: alphaMode,
        includeAudio: false,
        frameRate: frameRate,
        firstFrame: frameRange.lowerBound,
        lastFrame: frameRange.upperBound
    )
}

private func independentLinearFrame(
    width: Int, height: Int, rgba: [Float]
) throws -> StudioColorMetalFrame {
    let device = try #require(MTLCreateSystemDefaultDevice())
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false
    )
    descriptor.storageMode = .shared
    descriptor.usage = [.shaderRead]
    let texture = try #require(device.makeTexture(descriptor: descriptor))
    rgba.withUnsafeBytes { bytes in
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
            withBytes: bytes.baseAddress!,
            bytesPerRow: width * 4 * MemoryLayout<Float>.size
        )
    }
    return StudioColorMetalFrame(texture: texture)
}

@MainActor
private func sequentialPlaybackP95(
    sourceURL: URL,
    display: StudioColorMetalDisplay,
    input: StudioColorInputTransform,
    alpha: StudioColorAlphaAssociation,
    matrix: StudioColorSignalMatrix,
    range: StudioColorSignalRange
) async throws -> Double {
    let asset = AVURLAsset(url: sourceURL)
    let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
        track: track,
        outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_64RGBAHalf),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
    )
    output.alwaysCopiesSampleData = false
    reader.add(output)
    #expect(reader.startReading())
    let preview = StudioColorOutputTransform.catalog.first { $0.id == "aces2-rec709-sdr-100" }!
    var timings: [Double] = []
    while let sample = output.copyNextSampleBuffer(),
          let pixelBuffer = CMSampleBufferGetImageBuffer(sample) {
        let started = CACurrentMediaTime()
        let frame = try display.makeACEScgFrame(
            pixelBuffer: pixelBuffer, input: input, alpha: alpha,
            matrix: matrix, range: range
        )
        _ = try display.renderRGBA8(frame, output: preview)
        if !timings.isEmpty {
            timings.append((CACurrentMediaTime() - started) * 1_000)
        } else {
            timings = [0]
        }
    }
    let measured = timings.dropFirst().sorted()
    return measured[min(measured.count - 1, Int(Double(measured.count) * 0.95))]
}
