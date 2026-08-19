import CoreMedia
import Foundation
import Testing
@testable import ScreenSimulationNative
import StudioMedia

@Test @MainActor func configuredDNxFixtureDecodesThroughTheShippedFFmpegBoundary() async throws {
    guard let rawPath = ProcessInfo.processInfo.environment["SCREEN_DNX_INTEGRATION"],
          !rawPath.isEmpty
    else { return }
    let url = URL(fileURLWithPath: rawPath)
    let detection = await StudioMediaMetadataDetector.detect(url: url, isVideo: true)
    #expect(detection.colorModel == .ycbcr)
    #expect(detection.matrix == .bt709)
    #expect(detection.range == .video)
    #expect(detection.proposedInputTransformID == "input-rec709")
    #expect(detection.alpha == .ignore)
    let info = try NativeFFmpegMedia.probe(url: url)
    #expect(info.width > 0)
    #expect(info.height > 0)
    #expect(info.exactFrameRate.framesPerSecond > 0)
    let decoded = try NativeFFmpegMedia.decode(
        url: url, time: .zero, colorModel: .ycbcr, matrix: .bt709, range: .video
    )
    #expect(decoded.width == info.width)
    #expect(decoded.height == info.height)
    #expect(decoded.rgba.count == info.width * info.height * 4)
    let samplesAreFinite = decoded.rgba.allSatisfy { $0.isFinite }
    #expect(samplesAreFinite)
}
