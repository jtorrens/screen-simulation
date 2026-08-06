import Foundation

public enum StudioOutputFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case openEXR, dpx10RGB, tiff16
    case proRes4444, proRes4444XQ
    case h264Low, h264Medium, h264High
    case h265Low, h265Medium, h265High

    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .openEXR: "OpenEXR · half-float"
        case .dpx10RGB: "DPX · RGB 10 bits"
        case .tiff16: "TIFF · 16 bits"
        case .proRes4444: "QuickTime · ProRes 4444"
        case .proRes4444XQ: "QuickTime · ProRes 4444 XQ"
        case .h264Low: "H.264 · Calidad baja"
        case .h264Medium: "H.264 · Calidad media"
        case .h264High: "H.264 · Calidad alta"
        case .h265Low: "H.265 HDR · Calidad baja"
        case .h265Medium: "H.265 HDR · Calidad media"
        case .h265High: "H.265 HDR · Calidad alta"
        }
    }
    public var isMovie: Bool {
        switch self {
        case .openEXR, .dpx10RGB, .tiff16: false
        default: true
        }
    }
    public var supportsAlpha: Bool {
        switch self {
        case .openEXR, .tiff16, .proRes4444, .proRes4444XQ: true
        default: false
        }
    }
    public var fileExtension: String {
        switch self {
        case .openEXR: "exr"
        case .dpx10RGB: "dpx"
        case .tiff16: "tiff"
        case .proRes4444, .proRes4444XQ: "mov"
        case .h264Low, .h264Medium, .h264High: "mp4"
        case .h265Low, .h265Medium, .h265High: "mov"
        }
    }
    public var bitsPerPixelPerFrame: Double? {
        switch self {
        case .h264Low: 0.06
        case .h264Medium: 0.10
        case .h264High: 0.16
        case .h265Low: 0.035
        case .h265Medium: 0.06
        case .h265High: 0.10
        default: nil
        }
    }

    public var supportedSignalRanges: [StudioSignalRange] {
        switch self {
        case .h264Low, .h264Medium, .h264High,
             .h265Low, .h265Medium, .h265High:
            [.video]
        case .openEXR, .dpx10RGB, .tiff16,
             .proRes4444, .proRes4444XQ:
            [.full]
        }
    }
}

public enum StudioRenderTarget: String, Codable, Sendable {
    case sdr, hdr, aces2065, acescg
}

public enum StudioRenderPipeline: String, Codable, Sendable {
    case aces
    case davinciColorManaged
}

public struct StudioRenderPreset: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var pipeline: StudioRenderPipeline
    public var target: StudioRenderTarget
    public var peakNits: Double
    public var display: String?
    public var view: String?
    public var authoritativeRoundtripNotes: String {
        switch (pipeline, target) {
        case (.aces, .sdr):
            "Proyecto ACES: asigna Inverse Display Rec.709 BT.1886 al clip y exporta con la misma ODT ACES SDR Rec.709. No añadas otra IDT ni otra ODT al clip display-referred."
        case (.aces, .hdr):
            "Proyecto ACES: asigna la inverse display Rec.2100 ST2084 correspondiente a \(peakNits.formatted()) nit y devuelve el resultado con la misma ODT ACES HDR."
        case (.aces, .aces2065):
            "Intercambio scene-linear: asigna ACES2065-1 al reimportar y exporta OpenEXR ACES2065-1 para conservar identidad."
        case (.aces, .acescg):
            "Intercambio scene-linear: asigna ACEScg al reimportar y exporta OpenEXR ACEScg para conservar identidad."
        case (.davinciColorManaged, .sdr):
            "DaVinci YRGB Color Managed: Input Rec.709 Gamma 2.4, Timeline DaVinci Wide Gamut / Intermediate y Output Rec.709 Gamma 2.4. Desactiva Auto Color Management para el clip."
        case (.davinciColorManaged, .hdr):
            "DaVinci YRGB Color Managed: Input Rec.2100 ST2084, Timeline DaVinci Wide Gamut / Intermediate y Output Rec.2100 ST2084 a \(peakNits.formatted()) nit."
        case (.davinciColorManaged, .acescg):
            "Intercambio scene-linear DCM: asigna ACEScg al clip y deja que DCM convierta a DaVinci Wide Gamut / Intermediate."
        default:
            "Asigna explícitamente el espacio de entrada indicado y no confíes en Auto Color Management."
        }
    }

    public static let builtIns: [Self] = [
        .init(id: UUID(uuidString: "D7F465F6-3E58-4E8E-BEF3-A71A91E34C01")!, name: "ACES · SDR", pipeline: .aces, target: .sdr, peakNits: 100, display: "Rec.1886 Rec.709 - Display", view: "ACES 2.0 - SDR 100 nits (Rec.709)"),
        .init(id: UUID(uuidString: "D7F465F6-3E58-4E8E-BEF3-A71A91E34C02")!, name: "ACES · HDR", pipeline: .aces, target: .hdr, peakNits: 1_000, display: "Rec.2100-PQ - Display", view: "ACES 2.0 - HDR 1000 nits (Rec.2020)"),
        .init(id: UUID(uuidString: "D7F465F6-3E58-4E8E-BEF3-A71A91E34C03")!, name: "DCM · SDR", pipeline: .davinciColorManaged, target: .sdr, peakNits: 100, display: "Rec.1886 Rec.709 - Display", view: "Video (colorimetric)"),
        .init(id: UUID(uuidString: "D7F465F6-3E58-4E8E-BEF3-A71A91E34C04")!, name: "DCM · HDR", pipeline: .davinciColorManaged, target: .hdr, peakNits: 1_000, display: "Rec.2100-PQ - Display", view: "Video (colorimetric)"),
        .init(id: UUID(uuidString: "D7F465F6-3E58-4E8E-BEF3-A71A91E34C05")!, name: "ACES2065-1 · EXR", pipeline: .aces, target: .aces2065, peakNits: 0, display: nil, view: nil),
        .init(id: UUID(uuidString: "D7F465F6-3E58-4E8E-BEF3-A71A91E34C06")!, name: "ACEScg · EXR", pipeline: .aces, target: .acescg, peakNits: 0, display: nil, view: nil),
        .init(id: UUID(uuidString: "D7F465F6-3E58-4E8E-BEF3-A71A91E34C07")!, name: "DCM · EXR (ACEScg)", pipeline: .davinciColorManaged, target: .acescg, peakNits: 0, display: nil, view: nil),
    ]
}

/// Immutable options owned by one render job. A global preset only seeds these
/// fields and is never retained as a dynamic dependency.
public struct StudioResolvedRenderConfiguration: Codable, Equatable, Sendable {
    public let format: StudioOutputFormat
    public let pipeline: StudioRenderPipeline
    public let target: StudioRenderTarget
    public let peakNits: Double
    public let display: String?
    public let view: String?
    public let signalRange: StudioSignalRange
    public let alpha: StudioAlphaMode
    public let includeAudio: Bool
    public let frameRate: Double
    public let firstFrame: Int
    public let lastFrame: Int

    public init(
        format: StudioOutputFormat,
        pipeline: StudioRenderPipeline,
        target: StudioRenderTarget,
        peakNits: Double,
        display: String?,
        view: String?,
        signalRange: StudioSignalRange,
        alpha: StudioAlphaMode,
        includeAudio: Bool,
        frameRate: Double,
        firstFrame: Int,
        lastFrame: Int
    ) {
        self.format = format
        self.pipeline = pipeline
        self.target = target
        self.peakNits = peakNits
        self.display = display
        self.view = view
        self.signalRange = signalRange
        self.alpha = alpha
        self.includeAudio = includeAudio
        self.frameRate = frameRate
        self.firstFrame = firstFrame
        self.lastFrame = lastFrame
    }

    public var frameRange: ClosedRange<Int> { firstFrame ... lastFrame }
}

public enum StudioRenderRange: String, CaseIterable, Identifiable, Sendable {
    case all, inOut
    public var id: String { rawValue }
}

public enum StudioRenderJobStatus: String, Sendable {
    case pending, running, completed, failed, cancelled
}
