@preconcurrency import AVFoundation
import Foundation
import CoreMedia
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
    let display = try StudioColorMetalDisplay()
    let width = 8
    let height = 2
    let source = identityPattern(width: width, height: height)
    let frame = try display.makeACEScgFrame(
        width: width, height: height, encodedRGBA: source,
        input: StudioColorInputTransform.catalog.first { $0.id == "acescg" }!,
        alpha: .straight
    )
    let expected = try display.readLinearRGBA(frame)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-native-exr-\(UUID().uuidString)")
    _ = try await NativeOutputRenderer.render(
        configuration: renderConfiguration(
            format: .openEXR, preset: StudioRenderPreset.builtIns[5],
            alpha: .straight, signalRange: .full, frameRange: 12 ... 12
        ),
        destination: root, audioSource: nil,
        display: display, frameProvider: { _ in frame }, progress: { _, _ in }
    )
    let url = root.appendingPathComponent("ScreenSimulation/ScreenSimulation-00000012.exr")
    let exrBytes = try Data(contentsOf: url)
    let chunkTable = try firstEXRChunkOffset(in: exrBytes)
    #expect(chunkTable.offset >= UInt64(chunkTable.minimumOffset))
    #expect(chunkTable.offset < UInt64(exrBytes.count))
    let session = NativeMediaSession()
    _ = try session.openImages([url], frameRate: .fps24)
    let sample = try #require(try await session.exactSample(at: .zero))
    let decoded = try display.makeACEScgFrame(
        pixelBuffer: sample.pixelBuffer,
        input: StudioColorInputTransform.catalog.first { $0.id == "acescg" }!,
        alpha: .straight, matrix: .bt709, range: .full
    )
    let actual = try display.readLinearRGBA(decoded)
    #expect(actual.count == expected.count)
    #expect(zip(actual, expected).map { abs($0 - $1) }.max() ?? 0 <= 0.001)
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
    frameRange: ClosedRange<Int>
) -> StudioResolvedRenderConfiguration {
    let alphaMode: StudioAlphaMode = switch alpha {
    case .straight: .straight
    case .premultiplied: .premultiplied
    case .ignore: .ignore
    }
    return StudioResolvedRenderConfiguration(
        outputType: .standard,
        jobName: "ScreenSimulation",
        overwritePolicy: .failIfExists,
        fusionScene: nil,
        composition: .deviceOnly,
        motionBlurEnabled: false,
        motionSamples: 8,
        format: format,
        pipeline: preset.pipeline,
        target: preset.target,
        peakNits: preset.peakNits,
        display: preset.display,
        view: preset.view,
        vfxInterchangeEncodingID: preset.target == .vfxLog
            ? "arri-logc4-awg4" : nil,
        pixelEncoding: format.defaultPixelEncoding,
        signalRange: signalRange,
        alpha: alphaMode,
        includeAudio: false,
        frameRate: frameRate,
        firstFrame: frameRange.lowerBound,
        lastFrame: frameRange.upperBound
    )
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
