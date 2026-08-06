import Foundation
import CoreMedia
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
