import Foundation
import StudioMedia
import Testing
@testable import ScreenSimulationNative

@Test @MainActor func outputQueueOwnsSequentialJobLifecycle() async {
    let controller = NativeOutputQueueController()
    let configuration = outputQueueTestConfiguration()
    controller.enqueue(
        destination: URL(fileURLWithPath: "/tmp/first.mov"),
        configuration: configuration
    )
    controller.enqueue(
        destination: URL(fileURLWithPath: "/tmp/second.mov"),
        configuration: configuration
    )

    controller.run(operation: { job, progress in
        progress(1, 2)
        progress(2, 2)
        return job.destination
    }, onFailure: { _ in })

    while controller.isRendering { await Task.yield() }
    #expect(controller.jobs.map(\.state) == [.completed, .completed])
    #expect(controller.jobs.map(\.progress) == [1, 1])
    #expect(controller.jobs.map(\.detail) == ["first.mov", "second.mov"])
}

@Test @MainActor func outputQueuePublishesFailureWithoutASecondLifecycleOwner() async {
    struct ExpectedFailure: LocalizedError {
        var errorDescription: String? { "fallo controlado" }
    }
    let controller = NativeOutputQueueController()
    controller.enqueue(
        destination: URL(fileURLWithPath: "/tmp/failure.mov"),
        configuration: outputQueueTestConfiguration()
    )
    var failure: String?
    controller.run(
        operation: { _, _ in throw ExpectedFailure() },
        onFailure: { failure = $0 }
    )
    while controller.isRendering { await Task.yield() }
    #expect(controller.jobs.first?.state == .failed)
    #expect(controller.jobs.first?.detail == "fallo controlado")
    #expect(failure == "fallo controlado")
}

private func outputQueueTestConfiguration() -> StudioResolvedRenderConfiguration {
    StudioResolvedRenderConfiguration(
        format: .proRes4444,
        pipeline: .aces,
        target: .sdr,
        peakNits: 100,
        display: "sRGB",
        view: "ACES 2.0 - SDR 100 nits (Rec.709)",
        pixelEncoding: .yuv44412,
        signalRange: .video,
        alpha: .straight,
        includeAudio: false,
        frameRate: .fps24,
        firstFrame: 0,
        lastFrame: 1
    )
}
