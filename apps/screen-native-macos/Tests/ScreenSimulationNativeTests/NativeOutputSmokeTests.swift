import Foundation
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
        includeAlpha: false, includeAudio: false, audioSource: nil,
        display: display, frameProvider: { _ in frame }, progress: { _, _ in }
    )
    #expect(FileManager.default.fileExists(atPath: movie.path))

    let exrDirectory = root.appendingPathComponent("exr")
    _ = try await NativeOutputRenderer.render(
        format: .openEXR, preset: StudioRenderPreset.builtIns[5], peakNits: 0,
        frameRate: 24, frameRange: 7 ... 8, destination: exrDirectory,
        includeAlpha: true, includeAudio: false, audioSource: nil,
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
