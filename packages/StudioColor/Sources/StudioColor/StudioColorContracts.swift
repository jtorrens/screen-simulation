import CoreGraphics
import Foundation

public struct StudioColorInputTransform: Hashable, Identifiable, Sendable {
    public enum Processor: Hashable, Sendable {
        case colorSpace(String)
        case inverseDisplay(display: String, view: String)
    }

    public let id: String
    public let label: String
    public let processor: Processor

    public init(id: String, label: String, processor: Processor) {
        self.id = id
        self.label = label
        self.processor = processor
    }

    public static let catalog: [Self] = [
        .init(
            id: "display-rec709-aces2-sdr",
            label: "Display · Rec.709 (ACES 2.0 SDR)",
            processor: .inverseDisplay(
                display: "Rec.1886 Rec.709 - Display",
                view: "ACES 2.0 - SDR 100 nits (Rec.709)"
            )
        ),
        .init(
            id: "display-srgb-aces2-sdr",
            label: "Display · sRGB (ACES 2.0 SDR)",
            processor: .inverseDisplay(
                display: "sRGB - Display",
                view: "ACES 2.0 - SDR 100 nits (Rec.709)"
            )
        ),
        .init(
            id: "display-rec2100-pq-aces2-hdr-1000",
            label: "Display · Rec.2100 PQ (ACES 2.0 HDR 1000)",
            processor: .inverseDisplay(
                display: "Rec.2100-PQ - Display",
                view: "ACES 2.0 - HDR 1000 nits (Rec.2020)"
            )
        ),
        .init(
            id: "display-rec709-gamma24-dcm",
            label: "Display · Rec.709 Gamma 2.4 (DCM)",
            processor: .colorSpace("Gamma 2.4 Encoded Rec.709")
        ),
        .init(
            id: "display-rec2100-pq-dcm",
            label: "Display · Rec.2100 ST2084 (DCM)",
            processor: .inverseDisplay(
                display: "Rec.2100-PQ - Display",
                view: "Video (colorimetric)"
            )
        ),
        .init(id: "input-rec709", label: "Camera · Rec.709", processor: .colorSpace("Input - Rec.709")),
        .init(id: "srgb-encoded-rec709", label: "sRGB encoded Rec.709", processor: .colorSpace("sRGB Encoded Rec.709 (sRGB)")),
        .init(id: "acescg", label: "ACEScg (identity)", processor: .colorSpace("ACEScg")),
        .init(id: "arri-logc3-ei800", label: "ARRI LogC3 (EI800)", processor: .colorSpace("ARRI LogC3 (EI800)")),
        .init(id: "arri-logc4", label: "ARRI LogC4", processor: .colorSpace("ARRI LogC4")),
        .init(id: "bmd-film-gen5", label: "Blackmagic Film Gen 5", processor: .colorSpace("BMDFilm WideGamut Gen5")),
        .init(id: "davinci-intermediate", label: "DaVinci Intermediate", processor: .colorSpace("DaVinci Intermediate WideGamut")),
        .init(id: "canon-log3", label: "Canon Log 3 Cinema Gamut D55", processor: .colorSpace("CanonLog3 CinemaGamut D55")),
        .init(id: "vlog-vgamut", label: "V-Log V-Gamut", processor: .colorSpace("V-Log V-Gamut")),
        .init(id: "log3g10", label: "Log3G10 REDWideGamutRGB", processor: .colorSpace("Log3G10 REDWideGamutRGB")),
        .init(id: "slog3-sgamut3-cine", label: "S-Log3 S-Gamut3.Cine", processor: .colorSpace("S-Log3 S-Gamut3.Cine")),
    ]
}

public struct StudioColorOutputTransform: Hashable, Identifiable, Sendable {
    public enum Encoding: Equatable, Sendable {
        case linearRec709Raw, acescgRaw, sRGB, rec709, displayP3, displayP3EDR, rec2100PQ
    }
    public enum Processor: Hashable, Sendable {
        case displayView(display: String, view: String)
        case colorSpace(String)
    }

    public let id: String
    public let label: String
    public let display: String
    public let view: String
    public let encoding: Encoding
    public let processor: Processor

    public init(
        id: String,
        label: String,
        display: String,
        view: String,
        encoding: Encoding
    ) {
        self.id = id
        self.label = label
        self.display = display
        self.view = view
        self.encoding = encoding
        processor = .displayView(display: display, view: view)
    }

    public init(
        id: String,
        label: String,
        colorSpace: String,
        encoding: Encoding
    ) {
        self.id = id
        self.label = label
        display = ""
        view = ""
        self.encoding = encoding
        processor = .colorSpace(colorSpace)
    }

    public static let catalog: [Self] = [
        .init(
            id: "aces2-srgb-sdr-100",
            label: "ACES 2.0 · sRGB SDR 100 nit",
            display: "sRGB - Display",
            view: "ACES 2.0 - SDR 100 nits (Rec.709)",
            encoding: .sRGB
        ),
        .init(
            id: "aces2-rec709-sdr-100",
            label: "ACES 2.0 · Rec.709 SDR 100 nit",
            display: "Rec.1886 Rec.709 - Display",
            view: "ACES 2.0 - SDR 100 nits (Rec.709)",
            encoding: .rec709
        ),
        .init(
            id: "aces2-display-p3-sdr-100",
            label: "Display P3 · SDR 100 nit",
            display: "Display P3 - Display",
            view: "ACES 2.0 - SDR 100 nits (P3 D65)",
            encoding: .displayP3
        ),
        .init(
            id: "aces2-dci-p3-sdr-100",
            label: "DCI-P3 · SDR 100 nit",
            display: "P3-D65 - Display",
            view: "ACES 2.0 - SDR 100 nits (P3 D65)",
            encoding: .displayP3
        ),
        .init(
            id: "aces2-display-p3-edr-1000",
            label: "Display P3 · EDR 1000 nit",
            display: "Display P3 HDR - Display",
            view: "ACES 2.0 - HDR 1000 nits (P3 D65)",
            encoding: .displayP3EDR
        ),
        .init(
            id: "aces2-rec2100-pq-1000",
            label: "ACES 2.0 · Rec.2100 PQ 1000 nit",
            display: "Rec.2100-PQ - Display",
            view: "ACES 2.0 - HDR 1000 nits (Rec.2020)",
            encoding: .rec2100PQ
        ),
        .init(
            id: "acescg-raw",
            label: "ACEScg Raw · sin ODT",
            colorSpace: "Linear Rec.709 (sRGB)",
            encoding: .linearRec709Raw
        ),
    ]

    /// Technical scene-linear transport for downstream systems that explicitly
    /// understand ACEScg. It is intentionally absent from the Mac preview catalog.
    public static let technicalACEScgRaw = Self(
        id: "acescg-raw-technical",
        label: "ACEScg Raw técnico · sin ODT",
        colorSpace: "ACEScg",
        encoding: .acescgRaw
    )

    public var colorSpace: CGColorSpace? {
        switch encoding {
        // Raw inspection deliberately sends linear Rec.709 values as display
        // codes, so ColorSync does not add an encoding curve that lifts them.
        case .linearRec709Raw: CGColorSpace(name: CGColorSpace.sRGB)
        case .acescgRaw: CGColorSpace(name: CGColorSpace.acescgLinear)
        case .sRGB: CGColorSpace(name: CGColorSpace.sRGB)
        case .rec709: CGColorSpace(name: CGColorSpace.itur_709)
        case .displayP3: CGColorSpace(name: CGColorSpace.displayP3)
        case .displayP3EDR: CGColorSpace(name: CGColorSpace.displayP3)
        case .rec2100PQ: CGColorSpace(name: CGColorSpace.itur_2100_PQ)
        }
    }

    public var declaredSignalDescription: String {
        switch encoding {
        case .linearRec709Raw: "RGB lineal Rec.709 · sin curva"
        case .acescgRaw: "ACEScg lineal"
        case .sRGB: "sRGB · IEC 61966-2-1"
        case .rec709: "Rec.709 · SDR"
        case .displayP3: "Display P3 · SDR"
        case .displayP3EDR: "Display P3 · EDR"
        case .rec2100PQ: "Rec.2100 · PQ"
        }
    }
}

public enum StudioColorAlphaAssociation: String, CaseIterable, Identifiable, Sendable {
    case straight
    case premultiplied
    case ignore

    public var id: String { rawValue }
}

public enum StudioColorSignalMatrix: String, Sendable {
    case bt601, bt709, bt2020
}

public enum StudioColorSignalRange: String, Sendable {
    case video, full
}

public struct StudioColorLinearFrame: Sendable {
    public let width: Int
    public let height: Int
    public var premultipliedRGBA: [Float]

    public init(width: Int, height: Int, premultipliedRGBA: [Float]) throws {
        guard width > 0, height > 0,
              premultipliedRGBA.count == width * height * 4
        else { throw StudioColorError.invalidPixelBuffer }
        self.width = width
        self.height = height
        self.premultipliedRGBA = premultipliedRGBA
    }
}
