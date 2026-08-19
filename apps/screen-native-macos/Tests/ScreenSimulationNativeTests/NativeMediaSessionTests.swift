import CoreMedia
import StudioMedia
import Testing
@testable import ScreenSimulationNative

@Test @MainActor func mediaSampleTimeRetainsTheFirstAndLastAvailableFrames() throws {
    let rate = try ExactFrameRate(numerator: 24, denominator: 1)
    let before = NativeMediaSession.retainedDecodeTime(
        CMTime(value: -1, timescale: 48),
        frameCount: 100,
        exactFrameRate: rate
    )
    let inside = NativeMediaSession.retainedDecodeTime(
        CMTime(value: 125, timescale: 48),
        frameCount: 100,
        exactFrameRate: rate
    )
    let after = NativeMediaSession.retainedDecodeTime(
        CMTime(value: 10_000, timescale: 24),
        frameCount: 100,
        exactFrameRate: rate
    )

    #expect(before == .zero)
    #expect(inside == CMTime(value: 125, timescale: 48))
    #expect(after == CMTime(value: 99, timescale: 24))
}
