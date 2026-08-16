import Foundation
import Testing
@testable import ScreenSimulationNative

private func solidFrame(index: Int64, value: UInt8, width: Int = 32, height: Int = 16)
    -> AVFoundationRecordingFrame
{
    var rgba = [UInt8](repeating: value, count: width * height * 4)
    for alpha in stride(from: 3, to: rgba.count, by: 4) { rgba[alpha] = 255 }
    return .init(frameIndex: index, rgba8: rgba)
}

@Test func videoRequestRejectsMissingOrReorderedFrames() {
    let request = AVFoundationRecordingRequest(
        codec: .h264High8, width: 32, height: 16,
        frameRateNumerator: 24, frameRateDenominator: 1,
        firstFrameIndex: 1001, bitsPerSecond: 1_000_000,
        fixedGOPFrames: 12, maximumBFrames: 2,
        frames: [solidFrame(index: 1001, value: 16), solidFrame(index: 1003, value: 128)]
    )
    #expect(throws: AVFoundationRecordingError.nonChronologicalSequence) {
        try request.validated()
    }
}

@Test func h264RoundTripConsumesOneChronologicalSequence() throws {
    let request = AVFoundationRecordingRequest(
        codec: .h264High8, width: 32, height: 16,
        frameRateNumerator: 24, frameRateDenominator: 1,
        firstFrameIndex: 1001, bitsPerSecond: 2_000_000,
        fixedGOPFrames: 12, maximumBFrames: 2,
        frames: [
            solidFrame(index: 1001, value: 16),
            solidFrame(index: 1002, value: 96),
            solidFrame(index: 1003, value: 224),
        ]
    )
    let result = try AVFoundationRecordingAdapter.roundTrip(request)
    #expect(result.frames.map(\.frameIndex) == [1001, 1002, 1003])
    #expect(result.frames.allSatisfy { $0.rgba8.count == 32 * 16 * 4 })
    #expect(!result.encodedData.isEmpty)
    #expect(result.encodedSHA256.count == 32)
}
