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
}

public enum StudioRenderTarget: String, Codable, Sendable {
    case sdr, hdr, aces2065, acescg
}

public struct StudioRenderPreset: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let name: String
    public let target: StudioRenderTarget
    public var peakNits: Double
    public let display: String?
    public let view: String?

    public static let builtIns: [Self] = [
        .init(id: UUID(uuidString: "D7F465F6-3E58-4E8E-BEF3-A71A91E34C01")!, name: "ACES · SDR", target: .sdr, peakNits: 100, display: "Rec.1886 Rec.709 - Display", view: "ACES 2.0 - SDR 100 nits (Rec.709)"),
        .init(id: UUID(uuidString: "D7F465F6-3E58-4E8E-BEF3-A71A91E34C02")!, name: "ACES · HDR", target: .hdr, peakNits: 1_000, display: "Rec.2100-PQ - Display", view: "ACES 2.0 - HDR 1000 nits (Rec.2020)"),
        .init(id: UUID(uuidString: "D7F465F6-3E58-4E8E-BEF3-A71A91E34C03")!, name: "DCM · SDR", target: .sdr, peakNits: 100, display: "Rec.1886 Rec.709 - Display", view: "ACES 2.0 - SDR 100 nits (Rec.709)"),
        .init(id: UUID(uuidString: "D7F465F6-3E58-4E8E-BEF3-A71A91E34C04")!, name: "DCM · HDR", target: .hdr, peakNits: 1_000, display: "Rec.2100-PQ - Display", view: "ACES 2.0 - HDR 1000 nits (Rec.2020)"),
        .init(id: UUID(uuidString: "D7F465F6-3E58-4E8E-BEF3-A71A91E34C05")!, name: "ACES2065-1 · EXR", target: .aces2065, peakNits: 0, display: nil, view: nil),
        .init(id: UUID(uuidString: "D7F465F6-3E58-4E8E-BEF3-A71A91E34C06")!, name: "ACEScg · EXR", target: .acescg, peakNits: 0, display: nil, view: nil),
        .init(id: UUID(uuidString: "D7F465F6-3E58-4E8E-BEF3-A71A91E34C07")!, name: "DCM · EXR (ACEScg)", target: .acescg, peakNits: 0, display: nil, view: nil),
    ]
}

public enum StudioRenderRange: String, CaseIterable, Identifiable, Sendable {
    case all, inOut
    public var id: String { rawValue }
}

public enum StudioRenderJobStatus: String, Sendable {
    case pending, running, completed, failed, cancelled
}
