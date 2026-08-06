@preconcurrency import AVFoundation
import Foundation
import CoreMedia
import QuartzCore
import StudioColor
import StudioMedia
import Testing
@testable import ScreenSimulationNative

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
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-native-output-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let movie = try await NativeOutputRenderer.render(
        format: .h264High, preset: StudioRenderPreset.builtIns[0], peakNits: 100,
        frameRate: 24, frameRange: 0 ... 2,
        destination: root.appendingPathComponent("smoke.mp4"),
        alpha: .ignore, includeAudio: false, audioSource: nil,
        display: display, frameProvider: { _ in frame }, progress: { _, _ in }
    )
    #expect(FileManager.default.fileExists(atPath: movie.path))

    let exrDirectory = root.appendingPathComponent("exr")
    _ = try await NativeOutputRenderer.render(
        format: .openEXR, preset: StudioRenderPreset.builtIns[5], peakNits: 0,
        frameRate: 24, frameRange: 7 ... 8, destination: exrDirectory,
        alpha: .premultiplied, includeAudio: false, audioSource: nil,
        display: display, frameProvider: { _ in frame }, progress: { _, _ in }
    )
    #expect(FileManager.default.fileExists(
        atPath: exrDirectory.appendingPathComponent("ScreenSimulation-00000007.exr").path
    ))
    #expect(FileManager.default.fileExists(
        atPath: exrDirectory.appendingPathComponent("ScreenSimulation-00000008.exr").path
    ))

    let tiff = root.appendingPathComponent("current.tiff")
    try NativeOutputRenderer.renderCurrentFrame(
        frame: frame, displayTransform: StudioColorOutputTransform.catalog[0],
        destination: tiff, display: display
    )
    #expect(FileManager.default.fileExists(atPath: tiff.path))
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
        format: .openEXR, preset: StudioRenderPreset.builtIns[5], peakNits: 0,
        frameRate: 24, frameRange: 12 ... 12, destination: root,
        alpha: .straight, includeAudio: false, audioSource: nil,
        display: display, frameProvider: { _ in frame }, progress: { _, _ in }
    )
    let url = root.appendingPathComponent("ScreenSimulation-00000012.exr")
    let session = NativeMediaSession()
    _ = try session.openImages([url])
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

@Test @MainActor func proRes4444RoundtripPreservesFramesMetadataAndAlpha() async throws {
    for alpha in [StudioColorAlphaAssociation.straight, .premultiplied] {
        let result = try await movieRoundtrip(format: .proRes4444, alpha: alpha)
        #expect(result.detection.proposedInputTransformID == "display-rec709-aces2-sdr")
        #expect(result.detection.hasAlpha)
        #expect(result.detection.alpha == (alpha == .straight ? .straight : .premultiplied))
        #expect(result.frameRate == 24)
        #expect(result.frameCount == 3)
        #expect(result.maximumError <= 0.018, "ProRes \(alpha.rawValue) max \(result.maximumError)")
        #expect(result.rootMeanSquareError <= 0.0025, "ProRes \(alpha.rawValue) RMSE \(result.rootMeanSquareError)")
        print("PRORES alpha=\(alpha.rawValue) max=\(result.maximumError) rmse=\(result.rootMeanSquareError)")
    }
}

@Test @MainActor func h264RoundtripSeparatesCodecLossFromColorContract() async throws {
    let result = try await movieRoundtrip(format: .h264High, alpha: .ignore)
    #expect(result.detection.proposedInputTransformID == "display-rec709-aces2-sdr")
    #expect(!result.detection.hasAlpha)
    #expect(result.detection.matrix == .bt709)
    #expect(result.frameRate == 24)
    #expect(result.frameCount == 3)
    #expect(result.maximumError <= 0.20, "H.264 max \(result.maximumError)")
    #expect(result.rootMeanSquareError <= 0.055, "H.264 RMSE \(result.rootMeanSquareError)")
    #expect(result.neutralRootMeanSquareError <= 0.012,
            "H.264 neutral/color-path RMSE \(result.neutralRootMeanSquareError)")
    print("H264 max=\(result.maximumError) rmse=\(result.rootMeanSquareError) neutral_rmse=\(result.neutralRootMeanSquareError)")
}

private struct MovieRoundtripResult {
    let detection: StudioMediaDetection
    let frameRate: Double
    let frameCount: Int
    let maximumError: Float
    let rootMeanSquareError: Float
    let neutralRootMeanSquareError: Float
}

@MainActor
private func movieRoundtrip(
    format: StudioOutputFormat,
    alpha: StudioColorAlphaAssociation
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
        format: format, preset: StudioRenderPreset.builtIns[0], peakNits: 100,
        frameRate: 24, frameRange: 0 ... 2, destination: destination,
        alpha: alpha, includeAudio: false, audioSource: nil,
        display: display, frameProvider: { frames[$0] }, progress: { _, _ in }
    )
    let detection = await StudioMediaMetadataDetector.detect(url: url, isVideo: true)
    let session = NativeMediaSession()
    let info = try await session.openVideo(url, hasAlpha: detection.hasAlpha)
    let inverse = StudioColorInputTransform.catalog.first {
        $0.id == "display-rec709-aces2-sdr"
    }!
    var squaredError: Double = 0
    var sampleCount = 0
    var neutralSquaredError: Double = 0
    var neutralSampleCount = 0
    var maximumError: Float = 0
    for frameIndex in 0 ..< 3 {
        let time = CMTime(value: CMTimeValue(frameIndex), timescale: 24)
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
        frameRate: info.frameRate,
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
    let sourceInfo = try await sourceSession.openVideo(sourceURL, hasAlpha: detection.hasAlpha)
    let display = try StudioColorMetalDisplay()
    let input = StudioColorInputTransform.catalog.first {
        $0.id == (detection.proposedInputTransformID ?? "display-rec709-aces2-sdr")
    }!
    let alpha: StudioColorAlphaAssociation = switch detection.alpha {
    case .premultiplied: .premultiplied
    case .ignore: .ignore
    case .straight, nil: detection.hasAlpha ? .straight : .ignore
    }
    let matrix: StudioColorSignalMatrix = detection.matrix == .bt2020 ? .bt2020
        : (detection.matrix == .bt601 ? .bt601 : .bt709)
    let range: StudioColorSignalRange = detection.range == .video ? .video : .full
    let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("golden-\(UUID().uuidString).mov")
    let playbackP95 = try await sequentialPlaybackP95(
        sourceURL: sourceURL, display: display, input: input,
        alpha: alpha, matrix: matrix, range: range
    )
    let renderedURL = try await NativeOutputRenderer.render(
        format: .proRes4444, preset: StudioRenderPreset.builtIns[0], peakNits: 100,
        frameRate: sourceInfo.frameRate,
        frameRange: 0 ... max(0, sourceInfo.frameCount - 1),
        destination: outputURL, alpha: alpha,
        includeAudio: false, audioSource: nil, display: display,
        frameProvider: { frameIndex in
            let time = CMTime(
                value: CMTimeValue(frameIndex),
                timescale: CMTimeScale(sourceInfo.frameRate.rounded())
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
    let outputInfo = try await outputSession.openVideo(renderedURL, hasAlpha: outputDetection.hasAlpha)
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
    print("GOLDEN source=\(sourceURL.lastPathComponent) frames=\(sourceInfo.frameCount) fps=\(sourceInfo.frameRate) linear_max=\(maximum) linear_rmse=\(rmse) display_max_code=\(displayMaximum) display_rmse_code=\(displayRMSE) sequential_decode_aces_preview_p95_ms=\(playbackP95) output=\(renderedURL.path)")
    #expect(outputInfo.frameCount == sourceInfo.frameCount)
    #expect(abs(outputInfo.frameRate - sourceInfo.frameRate) < 0.01)
    #expect(outputDetection.proposedInputTransformID == "display-rec709-aces2-sdr")
    #expect(displayMaximum <= 5)
    #expect(displayRMSE <= 1)
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
