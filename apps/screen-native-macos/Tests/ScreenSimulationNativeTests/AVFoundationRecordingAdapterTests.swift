import Foundation
import Testing
@testable import ScreenSimulationNative

private func solidFrame(index: Int64, value: Float, width: Int = 96, height: Int = 64)
    -> AVFoundationRecordingFrame
{
    var rgba = [Float](repeating: value, count: width * height * 4)
    for alpha in stride(from: 3, to: rgba.count, by: 4) { rgba[alpha] = 1 }
    return .init(frameIndex: index, rgba: rgba)
}

@Test func videoRequestRejectsMissingOrReorderedFrames() {
    let request = AVFoundationRecordingRequest(
        codec: .h264High8, color: .rec709, width: 96, height: 64,
        frameRateNumerator: 24, frameRateDenominator: 1,
        firstFrameIndex: 1001, bitsPerSecond: 1_000_000,
        frames: [solidFrame(index: 1001, value: 0.1), solidFrame(index: 1003, value: 0.5)]
    )
    #expect(throws: AVFoundationRecordingError.nonChronologicalSequence) {
        try request.validated()
    }
}

@Test func everyBundledVideoCodecPerformsAnIndependentFrameRoundTrip() throws {
    let cases: [(AVFoundationRecordingRequest.Codec, AVFoundationRecordingRequest.Color)] = [
        (.h264High8, .rec709),
        (.hevcMain10, .rec2100PQ),
        (.proRes422HQ, .rec2100PQ),
        (.proRes4444, .rec2100PQ),
    ]
    for (codec, color) in cases {
        let request = AVFoundationRecordingRequest(
            codec: codec, color: color, width: 96, height: 64,
            frameRateNumerator: 24, frameRateDenominator: 1,
            firstFrameIndex: 1001, bitsPerSecond: 4_000_000,
            frames: [solidFrame(index: 1001, value: 0.42)]
        )
        let result = try AVFoundationRecordingAdapter.roundTrip(request)
        #expect(result.frames.map(\.frameIndex) == [1001])
        #expect(result.frames[0].rgba.count == 96 * 64 * 4)
        #expect(result.frames[0].rgba.allSatisfy { $0.isFinite })
        #expect(!result.encodedData.isEmpty)
        #expect(result.encodedSHA256.count == 32)
    }
}
