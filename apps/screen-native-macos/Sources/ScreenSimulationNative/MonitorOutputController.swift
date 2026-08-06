import Foundation
import StudioColor
import StudioVideoOutput

enum MonitorOutputTransform: String, CaseIterable, Identifiable {
    case acescgRaw = "monitor.acescg.raw"
    case acesRec709SDR100 = "monitor.aces2.rec709-sdr-100"
    case acesRec2100PQ1000 = "monitor.aces2.rec2100-pq-1000"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .acescgRaw: "ACEScg Raw · sin ODT"
        case .acesRec709SDR100: "ACES 2.0 · Rec.709 SDR · 100 nits"
        case .acesRec2100PQ1000: "ACES 2.0 · Rec.2100 PQ · 1.000 nits"
        }
    }

    var signal: VideoOutputSignal {
        switch self {
        case .acescgRaw: .acescgRaw
        case .acesRec709SDR100: .rec709SDR
        case .acesRec2100PQ1000: .rec2100PQ
        }
    }

    var colorTransform: StudioColorOutputTransform {
        switch self {
        case .acescgRaw:
            StudioColorOutputTransform.technicalACEScgRaw
        case .acesRec709SDR100:
            StudioColorOutputTransform.catalog.first {
                $0.id == "aces2-rec709-sdr-100"
            }!
        case .acesRec2100PQ1000:
            StudioColorOutputTransform.catalog.first {
                $0.id == "aces2-rec2100-pq-1000"
            }!
        }
    }
}

@MainActor
final class MonitorOutputController: ObservableObject {
    @Published private(set) var report = DeckLinkRuntimeProbe.inspect()
    @Published private(set) var selectedDeviceID = ""
    @Published private(set) var selectedModeID = ""
    @Published private(set) var selectedTransform = MonitorOutputTransform.acesRec709SDR100
    @Published private(set) var selectedRange = VideoOutputRange.video
    @Published private(set) var selectedPixelFormat = VideoOutputPixelFormat.yuv8Bit422
    @Published private(set) var isEnabled = false
    @Published private(set) var isActive = false
    @Published private(set) var status = "Salida detenida"
    @Published var errorMessage: String?

    private let output = DeckLinkPreviewOutput()

    init() {
        selectDefaults()
    }

    var selectedDevice: VideoOutputDevice? {
        report.devices.first { $0.id == selectedDeviceID }
    }

    var selectedMode: VideoOutputMode? {
        selectedDevice?.modes.first { $0.identifier == selectedModeID }
    }

    func refresh() {
        stop()
        report = DeckLinkRuntimeProbe.inspect()
        selectDefaults()
    }

    func selectDevice(_ id: String) {
        guard id != selectedDeviceID else { return }
        stop()
        selectedDeviceID = id
        selectedModeID = selectedDevice?.modes.first?.identifier ?? ""
        resolveTransport()
    }

    func selectMode(_ id: String) {
        guard id != selectedModeID else { return }
        stop()
        selectedModeID = id
        resolveTransport()
    }

    func selectTransform(_ transform: MonitorOutputTransform) {
        guard transform != selectedTransform else { return }
        stop()
        selectedTransform = transform
        resolveTransport()
    }

    func selectRange(_ range: VideoOutputRange) {
        guard range != selectedRange else { return }
        stop()
        selectedRange = range
    }

    func selectPixelFormat(_ pixelFormat: VideoOutputPixelFormat) {
        guard pixelFormat != selectedPixelFormat else { return }
        stop()
        selectedPixelFormat = pixelFormat
    }

    func toggle(frame: StudioColorMetalFrame?, display: StudioColorMetalDisplay) {
        if isEnabled {
            stop()
            return
        }
        guard let frame else {
            errorMessage = "No hay una textura ACEScg disponible."
            return
        }
        isEnabled = true
        update(frame: frame, display: display)
    }

    func update(frame: StudioColorMetalFrame, display: StudioColorMetalDisplay) {
        guard isEnabled else { return }
        do {
            let configuration = try resolvedConfiguration()
            let rgba = try display.renderRGBAFloat(
                frame,
                output: selectedTransform.colorTransform
            )
            try output.display(
                rgba: rgba,
                width: frame.width,
                height: frame.height,
                configuration: configuration
            )
            errorMessage = nil
            isActive = true
            status = "(configuration.width) × (configuration.height) · "
                + "\(configuration.framesPerSecond) fps"
        } catch {
            stop()
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        output.stop()
        isEnabled = false
        isActive = false
        status = "Salida detenida"
    }

    private func resolvedConfiguration() throws -> VideoOutputConfiguration {
        guard let selectedDevice, let selectedMode else {
            throw MonitorOutputError.missingSelection
        }
        return try VideoOutputConfiguration(
            outputTransformID: selectedTransform.id,
            device: selectedDevice,
            mode: selectedMode,
            signal: selectedTransform.signal,
            range: selectedRange,
            pixelFormat: selectedPixelFormat
        )
    }

    private func selectDefaults() {
        let device = report.devices.first { !$0.modes.isEmpty }
        selectedDeviceID = device?.id ?? ""
        let mode = device?.modes.first {
            $0.width == 1_920 && $0.height == 1_080
                && $0.framesPerSecond == 25
        } ?? device?.modes.first
        selectedModeID = mode?.identifier ?? ""
        resolveTransport()
        if report.canEnumerateDevices, report.devices.isEmpty {
            status = "No se ha detectado hardware DeckLink"
        } else if !report.canEnumerateDevices {
            status = report.runtime.displayName
        }
    }

    private func resolveTransport() {
        guard let selectedMode else { return }
        if !selectedMode.supportedSignals.contains(selectedTransform.signal) {
            if selectedMode.supportedSignals.contains(.rec709SDR) {
                selectedTransform = .acesRec709SDR100
            } else if selectedMode.supportedSignals.contains(.rec2100PQ) {
                selectedTransform = .acesRec2100PQ1000
            } else {
                selectedTransform = .acescgRaw
            }
        }
        selectedRange = selectedMode.supportedRanges.contains(.video)
            ? .video : selectedMode.supportedRanges.first ?? .video
        let required: VideoOutputPixelFormat = switch selectedTransform.signal {
        case .rec709SDR: .yuv8Bit422
        case .rec2100PQ: .yuv10Bit422
        case .acescgRaw: .rgb10Bit444
        }
        selectedPixelFormat = selectedMode.supportedPixelFormats.contains(required)
            ? required : selectedMode.supportedPixelFormats.first ?? required
    }
}

private enum MonitorOutputError: Error, LocalizedError {
    case missingSelection

    var errorDescription: String? {
        "Selecciona un dispositivo y un modo DeckLink disponibles."
    }
}
