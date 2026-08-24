import Foundation

public enum StudioPixelEncoding: String, Codable, CaseIterable, Identifiable, Sendable {
    case yuv4208, yuv42010, yuv44412
    case rgb10, rgb44412, rgb16, rgba16Float

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .yuv4208: "Y′CbCr 4:2:0 · 8 bit"
        case .yuv42010: "Y′CbCr 4:2:0 · 10 bit"
        case .yuv44412: "Y′CbCr 4:4:4 · 12 bit"
        case .rgb10: "RGB 4:4:4 · 10 bit"
        case .rgb44412: "RGB 4:4:4 · 12 bit"
        case .rgb16: "RGB 4:4:4 · 16 bit"
        case .rgba16Float: "RGBA 4:4:4:4 · float16"
        }
    }
    public var isYUV: Bool {
        switch self {
        case .yuv4208, .yuv42010, .yuv44412: true
        case .rgb10, .rgb44412, .rgb16, .rgba16Float: false
        }
    }
}

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
    /// Fusion publishes an independent Device matte, so its media container must preserve alpha.
    /// Color encoding is deliberately not part of this capability: any selected delivery
    /// encoding may be written into any implemented alpha-capable format.
    public var supportsFusionScenePackage: Bool { supportsAlpha }
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

    public var supportedPixelEncodings: [StudioPixelEncoding] {
        switch self {
        case .h264Low, .h264Medium, .h264High,
             .h265Low, .h265Medium, .h265High:
            switch self {
            case .h264Low, .h264Medium, .h264High: [.yuv4208]
            default: [.yuv42010]
            }
        case .proRes4444, .proRes4444XQ: [.yuv44412, .rgb44412]
        case .openEXR: [.rgba16Float]
        case .dpx10RGB: [.rgb10]
        case .tiff16: [.rgb16]
        }
    }

    public var defaultPixelEncoding: StudioPixelEncoding {
        supportedPixelEncodings[0]
    }

    public func supports(target: StudioRenderTarget) -> Bool {
        switch self {
        case .h264Low, .h264Medium, .h264High:
            target == .sdr
        case .h265Low, .h265Medium, .h265High:
            target == .hdr
        case .proRes4444, .proRes4444XQ, .dpx10RGB, .tiff16:
            target == .sdr || target == .hdr
                || ((self == .proRes4444 || self == .proRes4444XQ)
                    && target == .vfxLog)
        case .openEXR:
            target == .acescg || target == .aces2065
        }
    }

    public func supportedSignalRanges(
        for encoding: StudioPixelEncoding
    ) -> [StudioSignalRange] {
        guard supportedPixelEncodings.contains(encoding) else { return [] }
        switch encoding {
        case .yuv4208, .yuv42010: return [.video, .full]
        case .yuv44412: return [.video, .full]
        case .rgb10, .rgb44412, .rgb16, .rgba16Float: return [.full]
        }
    }
}

public enum StudioRenderTarget: String, Codable, Sendable {
    case sdr, hdr, aces2065, acescg, vfxLog
}

public enum StudioRenderPipeline: String, Codable, Sendable {
    case aces
    case davinciColorManaged
}

public enum StudioVFXEditorialDeliveryContract {
    public static let presetID = UUID(
        uuidString: "D7F465F6-3E58-4E8E-BEF3-A71A91E34C0A"
    )!
    public static let colorEncodingID = "acescct-ap1"
    public static let rec709ColorEncodingID = "rec709-gamma24"
    public static let supportedColorEncodingIDs = ["acescct-ap1", "rec709-gamma24"]
    public static let rec709PeakNits = 100.0
    public static let rec709Display = "Rec.1886 Rec.709 - Display"
    public static let rec709View = "ACES 2.0 - SDR 100 nits (Rec.709)"
    public static let spillAlpha = 0.125
}

public enum StudioOutputType: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard
    case editorial
    case fusionScenePackage

    public var id: String { rawValue }
    public var usesStandardMediaRenderer: Bool { self != .fusionScenePackage }
    public var label: String {
        switch self {
        case .standard: "Render estándar"
        case .editorial: "Editorial"
        case .fusionScenePackage: "Fusion Scene Package"
        }
    }
}

public enum StudioSpillDeliveryMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case physicalLinear = "physical-linear"
    case editorialEncodedAdd = "editorial-encoded-add"

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .physicalLinear: "Físico lineal"
        case .editorialEncodedAdd: "Editorial Add · alpha 12,5%"
        }
    }
}

public struct StudioResolvedRenderRaster: Codable, Equatable, Sendable {
    public let width: UInt32
    public let height: UInt32
    public let placementID: String

    public init(width: UInt32, height: UInt32, placementID: String) {
        self.width = width
        self.height = height
        self.placementID = placementID
    }

    public func validate() throws {
        guard width > 0, height > 0,
              ["fit", "fill-crop", "one-to-one"].contains(placementID) else {
            throw StudioOutputContractError.invalidRenderRaster
        }
    }
}

public enum StudioOverwritePolicy: String, Codable, CaseIterable, Sendable {
    case failIfExists
    case replaceGeneratedFiles
}

public enum StudioFusionDOFMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case disabled
    case baked
    case fusion
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .disabled: "Sin DOF"
        case .baked: "Baked"
        case .fusion: "Fusion"
        }
    }
}

public enum StudioFusionResolutionMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case maximumProjectedDensity
    case nativeDevice
    case custom

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .maximumProjectedDensity: "Máxima resolución proyectada"
        case .nativeDevice: "Resolución nativa del Device"
        case .custom: "Personalizada"
        }
    }
}

public struct StudioFusionSceneConfiguration: Codable, Equatable, Sendable {
    public let dofMode: StudioFusionDOFMode
    public let resolutionMode: StudioFusionResolutionMode
    public let customActiveWidth: Int?
    public let customActiveHeight: Int?
    public let spillThresholdSceneLinear: Double
    public let spillFadeWidthPixels: Int

    public init(
        dofMode: StudioFusionDOFMode,
        resolutionMode: StudioFusionResolutionMode,
        customActiveWidth: Int?,
        customActiveHeight: Int?,
        spillThresholdSceneLinear: Double,
        spillFadeWidthPixels: Int
    ) {
        self.dofMode = dofMode
        self.resolutionMode = resolutionMode
        self.customActiveWidth = customActiveWidth
        self.customActiveHeight = customActiveHeight
        self.spillThresholdSceneLinear = spillThresholdSceneLinear
        self.spillFadeWidthPixels = spillFadeWidthPixels
    }

    public func validate() throws {
        guard spillThresholdSceneLinear.isFinite,
              spillThresholdSceneLinear > 0,
              spillFadeWidthPixels >= 0 else {
            throw StudioOutputContractError.invalidFusionSpillSupport
        }
        if resolutionMode == .custom {
            guard let customActiveWidth, let customActiveHeight,
                  customActiveWidth > 0, customActiveHeight > 0 else {
                throw StudioOutputContractError.invalidFusionCustomResolution
            }
        } else if customActiveWidth != nil || customActiveHeight != nil {
            throw StudioOutputContractError.unexpectedFusionCustomResolution
        }
    }

}

public enum StudioOutputContractError: Error, LocalizedError, Equatable {
    case invalidJobName
    case invalidFrameRange
    case invalidMotionSamples
    case invalidRenderRaster
    case invalidFusionSpillSupport
    case invalidFusionCustomResolution
    case unexpectedFusionCustomResolution
    case fusionConfigurationRequired
    case fusionConfigurationForbidden
    case fusionDeliveryConfigurationInvalid
    case separatedDeviceSpillDeliveryInvalid
    case editorialSpillDeliveryInvalid
    case wipReviewDeliveryInvalid

    public var errorDescription: String? {
        switch self {
        case .invalidJobName: "El nombre del trabajo no puede estar vacío."
        case .invalidFrameRange: "El rango del trabajo no es válido."
        case .invalidMotionSamples: "Las muestras de Motion Blur deben estar entre 2 y 64."
        case .invalidRenderRaster: "El raster de render requiere dimensiones y placement explícitos válidos."
        case .invalidFusionSpillSupport:
            "El threshold ACEScg scene-linear debe ser positivo y el fade no puede ser negativo."
        case .invalidFusionCustomResolution:
            "La resolución personalizada requiere ancho y alto positivos."
        case .unexpectedFusionCustomResolution:
            "Solo la resolución personalizada puede declarar ancho y alto propios."
        case .fusionConfigurationRequired:
            "Fusion Scene Package requiere su configuración explícita."
        case .fusionConfigurationForbidden:
            "Una salida estándar no puede contener configuración Fusion."
        case .fusionDeliveryConfigurationInvalid:
            "Fusion Scene Package requiere un formato implementado con alpha straight, preset compatible, Device + Spill y sin audio."
        case .separatedDeviceSpillDeliveryInvalid:
            "Device y Spill separados requiere un formato con alpha, Device straight y sin audio."
        case .editorialSpillDeliveryInvalid:
            "Editorial Add requiere Device/Spill separado, ACEScct/AP1 o Rec.709 Gamma 2.4, ProRes 4444 RGB Full Range, alpha straight y sin audio."
        case .wipReviewDeliveryInvalid:
            "WIP Review solo puede aplicarse a una composición estándar única y display/output encoded."
        }
    }
}

public struct StudioRenderPreset: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var pipeline: StudioRenderPipeline
    public var target: StudioRenderTarget
    public var peakNits: Double
    public var display: String?
    public var view: String?
    public var format: StudioOutputFormat = .proRes4444
    public var pixelEncoding: StudioPixelEncoding = .yuv44412
    public var signalRange: StudioSignalRange = .video
    public var alpha: StudioAlphaMode = .premultiplied
    public var includeAudio: Bool = false
    public var notes: String = ""

    public init(
        id: UUID,
        name: String,
        pipeline: StudioRenderPipeline,
        target: StudioRenderTarget,
        peakNits: Double,
        display: String?,
        view: String?,
        format: StudioOutputFormat = .proRes4444,
        pixelEncoding: StudioPixelEncoding = .yuv44412,
        signalRange: StudioSignalRange = .video,
        alpha: StudioAlphaMode = .premultiplied,
        includeAudio: Bool = false,
        notes: String = ""
    ) {
        self.id = id
        self.name = name
        self.pipeline = pipeline
        self.target = target
        self.peakNits = peakNits
        self.display = display
        self.view = view
        self.format = format
        self.pixelEncoding = pixelEncoding
        self.signalRange = signalRange
        self.alpha = alpha
        self.includeAudio = includeAudio
        self.notes = notes
    }
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
        case (_, .vfxLog):
            "Intercambio VFX: asigna al clip exactamente el Log/Gamut elegido para el render. La cámara sólo propone el valor inicial; no interpretes el archivo como Rec.709."
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

    public var fixedVFXInterchangeEncodingID: String? {
        id == StudioVFXEditorialDeliveryContract.presetID
            ? StudioVFXEditorialDeliveryContract.colorEncodingID : nil
    }

    public var supportsFusionScenePackage: Bool {
        id != StudioVFXEditorialDeliveryContract.presetID
    }

    public static let builtIns: [Self] = [
        .init(id: UUID(uuidString: "D7F465F6-3E58-4E8E-BEF3-A71A91E34C01")!, name: "ACES · SDR", pipeline: .aces, target: .sdr, peakNits: 100, display: "Rec.1886 Rec.709 - Display", view: "ACES 2.0 - SDR 100 nits (Rec.709)", notes: "Roundtrip ACES SDR Rec.709 BT.1886."),
        .init(id: UUID(uuidString: "D7F465F6-3E58-4E8E-BEF3-A71A91E34C02")!, name: "ACES · HDR", pipeline: .aces, target: .hdr, peakNits: 1_000, display: "Rec.2100-PQ - Display", view: "ACES 2.0 - HDR 1000 nits (Rec.2020)", notes: "Roundtrip ACES HDR Rec.2100 ST2084 1000 nit."),
        .init(id: UUID(uuidString: "D7F465F6-3E58-4E8E-BEF3-A71A91E34C03")!, name: "DCM · SDR", pipeline: .davinciColorManaged, target: .sdr, peakNits: 100, display: "Rec.1886 Rec.709 - Display", view: "Video (colorimetric)", notes: "Entrega Rec.709 Gamma 2.4 para DaVinci Wide Gamut / Intermediate."),
        .init(id: UUID(uuidString: "D7F465F6-3E58-4E8E-BEF3-A71A91E34C04")!, name: "DCM · HDR", pipeline: .davinciColorManaged, target: .hdr, peakNits: 1_000, display: "Rec.2100-PQ - Display", view: "Video (colorimetric)", notes: "Entrega Rec.2100 ST2084 para DaVinci Wide Gamut / Intermediate."),
        .init(id: UUID(uuidString: "D7F465F6-3E58-4E8E-BEF3-A71A91E34C05")!, name: "ACES2065-1 · EXR", pipeline: .aces, target: .aces2065, peakNits: 0, display: nil, view: nil, format: .openEXR, pixelEncoding: .rgba16Float, signalRange: .full, alpha: .straight, notes: "Intercambio scene-linear ACES2065-1."),
        .init(id: UUID(uuidString: "D7F465F6-3E58-4E8E-BEF3-A71A91E34C06")!, name: "ACEScg · EXR", pipeline: .aces, target: .acescg, peakNits: 0, display: nil, view: nil, format: .openEXR, pixelEncoding: .rgba16Float, signalRange: .full, alpha: .straight, notes: "Intercambio scene-linear ACEScg."),
        .init(id: UUID(uuidString: "D7F465F6-3E58-4E8E-BEF3-A71A91E34C07")!, name: "DCM · EXR (ACEScg)", pipeline: .davinciColorManaged, target: .acescg, peakNits: 0, display: nil, view: nil, format: .openEXR, pixelEncoding: .rgba16Float, signalRange: .full, alpha: .straight, notes: "Intercambio scene-linear ACEScg para DCM."),
        .init(id: UUID(uuidString: "D7F465F6-3E58-4E8E-BEF3-A71A91E34C08")!, name: "VFX · ProRes 4444", pipeline: .aces, target: .vfxLog, peakNits: 0, display: nil, view: nil, format: .proRes4444, pixelEncoding: .yuv44412, signalRange: .video, alpha: .straight, notes: "Log/Gamut VFX elegido explícitamente; sin ODT de display."),
        .init(id: UUID(uuidString: "D7F465F6-3E58-4E8E-BEF3-A71A91E34C09")!, name: "VFX · ProRes 4444 XQ", pipeline: .aces, target: .vfxLog, peakNits: 0, display: nil, view: nil, format: .proRes4444XQ, pixelEncoding: .yuv44412, signalRange: .video, alpha: .straight, notes: "Máxima calidad ProRes con Log/Gamut VFX elegido explícitamente; sin ODT de display."),
        .init(id: StudioVFXEditorialDeliveryContract.presetID, name: "VFX Editorial · ACEScct · ProRes 4444 XQ", pipeline: .aces, target: .vfxLog, peakNits: 0, display: nil, view: nil, format: .proRes4444XQ, pixelEncoding: .rgb44412, signalRange: .full, alpha: .straight, includeAudio: false, notes: "Contrato editorial estándar: ACEScct/AP1, RGB Full Range, alfa straight lineal y sin ODT de display."),
    ]
}

/// Immutable options owned by one render job. A global preset only seeds these
/// fields and is never retained as a dynamic dependency.
public struct StudioResolvedRenderConfiguration: Codable, Equatable, Sendable {
    public let outputType: StudioOutputType
    public let jobName: String
    public let versionSuffix: String
    public let overwritePolicy: StudioOverwritePolicy
    public let fusionScene: StudioFusionSceneConfiguration?
    public let composition: StudioRenderComposition
    public let spillDeliveryMode: StudioSpillDeliveryMode
    public let motionBlurMode: StudioRenderMotionBlurMode
    public let motionSamples: UInt16
    public let raster: StudioResolvedRenderRaster
    public let format: StudioOutputFormat
    public let pipeline: StudioRenderPipeline
    public let target: StudioRenderTarget
    public let peakNits: Double
    public let display: String?
    public let view: String?
    public let vfxInterchangeEncodingID: String?
    public let pixelEncoding: StudioPixelEncoding
    public let signalRange: StudioSignalRange
    public let alpha: StudioAlphaMode
    public let includeAudio: Bool
    public let frameRate: StudioFrameRate
    public let firstFrame: Int
    public let lastFrame: Int
    /// Immutable WIP Review settings captured by this render attempt.
    public let wipReview: StudioWIPReviewPreset?

    public init(
        outputType: StudioOutputType,
        jobName: String,
        versionSuffix: String,
        overwritePolicy: StudioOverwritePolicy,
        fusionScene: StudioFusionSceneConfiguration?,
        composition: StudioRenderComposition,
        spillDeliveryMode: StudioSpillDeliveryMode,
        motionBlurMode: StudioRenderMotionBlurMode,
        motionSamples: UInt16,
        raster: StudioResolvedRenderRaster,
        format: StudioOutputFormat,
        pipeline: StudioRenderPipeline,
        target: StudioRenderTarget,
        peakNits: Double,
        display: String?,
        view: String?,
        vfxInterchangeEncodingID: String?,
        pixelEncoding: StudioPixelEncoding,
        signalRange: StudioSignalRange,
        alpha: StudioAlphaMode,
        includeAudio: Bool,
        frameRate: StudioFrameRate,
        firstFrame: Int,
        lastFrame: Int,
        wipReview: StudioWIPReviewPreset? = nil
    ) {
        self.outputType = outputType
        self.jobName = jobName
        self.versionSuffix = versionSuffix
        self.overwritePolicy = overwritePolicy
        self.fusionScene = fusionScene
        self.composition = composition
        self.spillDeliveryMode = spillDeliveryMode
        self.motionBlurMode = motionBlurMode
        self.motionSamples = motionSamples
        self.raster = raster
        self.format = format
        self.pipeline = pipeline
        self.target = target
        self.peakNits = peakNits
        self.display = display
        self.view = view
        self.vfxInterchangeEncodingID = vfxInterchangeEncodingID
        self.pixelEncoding = pixelEncoding
        self.signalRange = signalRange
        self.alpha = alpha
        self.includeAudio = includeAudio
        self.frameRate = frameRate
        self.firstFrame = firstFrame
        self.lastFrame = lastFrame
        self.wipReview = wipReview
    }

    public var frameRange: ClosedRange<Int> { firstFrame ... lastFrame }
    public var physicalTemporalSamples: UInt16 {
        motionBlurMode == .physical ? motionSamples : 1
    }

    public func validate() throws {
        guard !jobName.isEmpty else { throw StudioOutputContractError.invalidJobName }
        guard !versionSuffix.contains("/"), !versionSuffix.contains("\\"),
              !versionSuffix.contains(":"),
              !versionSuffix.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw StudioOutputContractError.invalidJobName }
        guard firstFrame <= lastFrame else { throw StudioOutputContractError.invalidFrameRange }
        guard (2 ... 64).contains(motionSamples) else {
            throw StudioOutputContractError.invalidMotionSamples
        }
        try raster.validate()
        switch outputType {
        case .standard, .editorial:
            guard fusionScene == nil else {
                throw StudioOutputContractError.fusionConfigurationForbidden
            }
            if composition == .deviceAndSpillSeparate {
                guard format.supportsAlpha, alpha == .straight, !includeAudio else {
                    throw StudioOutputContractError.separatedDeviceSpillDeliveryInvalid
                }
            }
            if spillDeliveryMode == .editorialEncodedAdd {
                let colorContractIsValid = switch vfxInterchangeEncodingID {
                case StudioVFXEditorialDeliveryContract.colorEncodingID:
                    target == .vfxLog && peakNits == 0
                        && display == nil && view == nil
                case StudioVFXEditorialDeliveryContract.rec709ColorEncodingID:
                    target == .sdr
                        && peakNits == StudioVFXEditorialDeliveryContract.rec709PeakNits
                        && display == StudioVFXEditorialDeliveryContract.rec709Display
                        && view == StudioVFXEditorialDeliveryContract.rec709View
                default:
                    false
                }
                guard composition == .deviceAndSpillSeparate,
                      format == .proRes4444 || format == .proRes4444XQ,
                      pipeline == .aces, colorContractIsValid,
                      pixelEncoding == .rgb44412, signalRange == .full,
                      alpha == .straight, !includeAudio, wipReview == nil else {
                    throw StudioOutputContractError.editorialSpillDeliveryInvalid
                }
            }
            if let wipReview {
                guard composition != .deviceAndSpillSeparate,
                      target == .sdr || target == .hdr,
                      format != .openEXR,
                      alpha == .ignore else {
                    throw StudioOutputContractError.wipReviewDeliveryInvalid
                }
                try wipReview.validate()
                let expected: (
                    target: StudioRenderTarget, peakNits: Double,
                    display: String, view: String
                ) = switch wipReview.outputColorSpace {
                case .rec709Gamma24:
                    (.sdr, 100, "Rec.1886 Rec.709 - Display",
                     "ACES 2.0 - SDR 100 nits (Rec.709)")
                case .rec2100PQ:
                    (.hdr, 1_000, "Rec.2100-PQ - Display",
                     "ACES 2.0 - HDR 1000 nits (Rec.2020)")
                case .rec2100HLG:
                    (.hdr, wipReview.hlgPeakNits, "Rec.2100-HLG - Display",
                     "ACES 2.0 - HDR 1000 nits (P3 D65)")
                }
                guard pipeline == .aces, target == expected.target,
                      peakNits == expected.peakNits,
                      display == expected.display, view == expected.view,
                      format.supports(target: expected.target),
                      format.supportedPixelEncodings.contains(pixelEncoding),
                      format.supportedSignalRanges(for: pixelEncoding).contains(signalRange)
                else { throw StudioOutputContractError.wipReviewDeliveryInvalid }
            }
        case .fusionScenePackage:
            guard wipReview == nil else {
                throw StudioOutputContractError.wipReviewDeliveryInvalid
            }
            let colorContractIsComplete = switch target {
            case .sdr, .hdr:
                display != nil && view != nil && vfxInterchangeEncodingID == nil
            case .aces2065, .acescg:
                display == nil && view == nil && vfxInterchangeEncodingID == nil
            case .vfxLog:
                display == nil && view == nil
                    && vfxInterchangeEncodingID?.isEmpty == false
            }
            guard colorContractIsComplete,
                  format.supportsFusionScenePackage,
                  format.supportedPixelEncodings.contains(pixelEncoding),
                  format.supportedSignalRanges(for: pixelEncoding).contains(signalRange),
                  alpha == .straight, !includeAudio,
                  composition == .deviceAndSpillTogether,
                  spillDeliveryMode == .physicalLinear,
                  motionBlurMode == .disabled else {
                throw StudioOutputContractError.fusionDeliveryConfigurationInvalid
            }
            guard let fusionScene else {
                throw StudioOutputContractError.fusionConfigurationRequired
            }
            try fusionScene.validate()
        }
    }

    public func replacingOverwritePolicy(
        _ policy: StudioOverwritePolicy
    ) -> StudioResolvedRenderConfiguration {
        StudioResolvedRenderConfiguration(
            outputType: outputType, jobName: jobName, versionSuffix: versionSuffix,
            overwritePolicy: policy, fusionScene: fusionScene,
            composition: composition, spillDeliveryMode: spillDeliveryMode,
            motionBlurMode: motionBlurMode,
            motionSamples: motionSamples, raster: raster,
            format: format, pipeline: pipeline,
            target: target, peakNits: peakNits, display: display, view: view,
            vfxInterchangeEncodingID: vfxInterchangeEncodingID,
            pixelEncoding: pixelEncoding, signalRange: signalRange, alpha: alpha,
            includeAudio: includeAudio, frameRate: frameRate,
            firstFrame: firstFrame, lastFrame: lastFrame,
            wipReview: wipReview
        )
    }

}

public enum StudioRenderMotionBlurMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case disabled
    case physical
    case approximate2D = "approximate-2d"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .disabled: "Desactivado"
        case .physical: "Físico"
        case .approximate2D: "2D aproximado"
        }
    }
}

public enum StudioRenderComposition: String, CaseIterable, Identifiable, Codable, Sendable {
    case deviceAndSpillTogether
    case deviceAndSpillSeparate
    case fullComposite

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .deviceAndSpillTogether: "Device + Spill"
        case .deviceAndSpillSeparate: "Device y Spill separados"
        case .fullComposite: "Device + Spill + Plate"
        }
    }
}

public enum StudioRenderRange: String, CaseIterable, Identifiable, Sendable {
    case all, inOut
    public var id: String { rawValue }
}

public enum StudioRenderJobStatus: String, Sendable {
    case pending, running, completed, failed, cancelled
}
