import StudioVideoOutput
import Testing
@testable import ScreenSimulationNative

@Test func monitorODTResolvesIndependentlyFromPreviewAndRenderState() throws {
    let mode = try VideoOutputMode(
        identifier: "6D6F6465",
        name: "HD 1080p25",
        width: 1_920,
        height: 1_080,
        framesPerSecond: 25,
        supportedSignals: [.rec709SDR, .rec2100PQ],
        supportedRanges: [.video],
        supportedPixelFormats: [.yuv8Bit422, .yuv10Bit422]
    )
    let device = VideoOutputDevice(
        id: "decklink-1",
        name: "DeckLink",
        modes: [mode]
    )
    let transform = MonitorOutputTransform.acesRec2100PQ1000
    let configuration = try VideoOutputConfiguration(
        outputTransformID: transform.id,
        device: device,
        mode: mode,
        signal: transform.signal,
        range: .video,
        pixelFormat: .yuv10Bit422
    )

    #expect(configuration.outputTransformID == "monitor.aces2.rec2100-pq-1000")
    #expect(configuration.signal == .rec2100PQ)
    #expect(transform.colorTransform.id == "aces2-rec2100-pq-1000")
}

@Test func monitorRawUsesACEScgProcessorAndExplicitRGBTransport() throws {
    let mode = try VideoOutputMode(
        identifier: "6D6F6465",
        name: "HD 1080p25 RGB",
        width: 1_920,
        height: 1_080,
        framesPerSecond: 25,
        supportedSignals: [.acescgRaw],
        supportedRanges: [.video],
        supportedPixelFormats: [.rgb10Bit444]
    )
    let device = VideoOutputDevice(id: "decklink-rgb", name: "DeckLink RGB", modes: [mode])
    let transform = MonitorOutputTransform.acescgRaw
    let configuration = try VideoOutputConfiguration(
        outputTransformID: transform.id,
        device: device,
        mode: mode,
        signal: transform.signal,
        range: .video,
        pixelFormat: .rgb10Bit444
    )
    #expect(transform.colorTransform.id == "acescg-raw-technical")
    #expect(transform.colorTransform.processor == .colorSpace("ACEScg"))
    #expect(configuration.signal == .acescgRaw)
    #expect(configuration.pixelFormat == .rgb10Bit444)
}

@Test @MainActor func missingDeckLinkHardwareIsReportedWithoutSimulatedSuccess() {
    let controller = MonitorOutputController()
    if controller.report.devices.isEmpty {
        #expect(!controller.isActive)
        #expect(!controller.isEnabled)
        #expect(
            controller.status == "No se ha detectado hardware DeckLink"
                || controller.status == controller.report.runtime.displayName
        )
    }
}
