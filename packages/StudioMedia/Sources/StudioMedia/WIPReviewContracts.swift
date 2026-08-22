import Foundation

public struct StudioReviewColor: Codable, Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public func validate() throws {
        guard [red, green, blue, alpha].allSatisfy({ $0.isFinite && (0 ... 1).contains($0) }) else {
            throw StudioWIPReviewContractError.invalidColor
        }
    }
}

public enum StudioWIPOutputColorSpace: String, Codable, CaseIterable, Identifiable, Sendable {
    case rec709Gamma24
    case rec2100PQ
    case rec2100HLG
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .rec709Gamma24: "Rec.709 Gamma 2.4"
        case .rec2100PQ: "Rec.2100 PQ"
        case .rec2100HLG: "Rec.2100 HLG"
        }
    }
}

public enum StudioWIPReviewRaster: String, Codable, CaseIterable, Identifiable, Sendable {
    case output
    case hd1920x1080
    case uhd3840x2160
    case dci2K2048x1080
    case dci4K4096x2160
    case custom
    public var id: String { rawValue }
}

public enum StudioWIPPlacement: String, Codable, CaseIterable, Identifiable, Sendable {
    case identity, fit, fill, stretch, center
    public var id: String { rawValue }
}

public enum StudioWIPResampleFilter: String, Codable, CaseIterable, Identifiable, Sendable {
    case bilinear, bicubic, lanczos
    public var id: String { rawValue }
}

public enum StudioWIPBlankingAspect: String, Codable, CaseIterable, Identifiable, Sendable {
    case ratio178, ratio185, ratio200, ratio239, custom
    public var id: String { rawValue }
}

public enum StudioWIPFontStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case regular, bold, italic, boldItalic
    public var id: String { rawValue }
}

public enum StudioWIPGraphicsWhiteMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic, nits
    public var id: String { rawValue }
}

public enum StudioWIPFrameRateMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case render, override
    public var id: String { rawValue }
}

public enum StudioWIPCalculatedField: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case frameRelative
    case frame
    case timecode
    case date
    case outputFilename
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .none: "Ninguno"
        case .frameRelative: "Frame relativo"
        case .frame: "Frame"
        case .timecode: "Timecode"
        case .date: "Fecha"
        case .outputFilename: "File Name"
        }
    }
}

public enum StudioWIPZonePosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case topLeft, topCenter, topRight, bottomLeft, bottomCenter, bottomRight
    public var id: String { rawValue }
}

public struct StudioWIPTextOverride: Codable, Equatable, Hashable, Sendable {
    public var enabled: Bool
    public var value: Double
    public init(enabled: Bool = false, value: Double = 0) {
        self.enabled = enabled
        self.value = value
    }
}

public struct StudioWIPColorOverride: Codable, Equatable, Hashable, Sendable {
    public var enabled: Bool
    public var value: StudioReviewColor
    public init(enabled: Bool = false, value: StudioReviewColor) {
        self.enabled = enabled
        self.value = value
    }
}

public struct StudioWIPReviewZone: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: StudioWIPZonePosition { position }
    public var position: StudioWIPZonePosition
    public var enabled: Bool
    public var prefix: String
    public var calculatedField: StudioWIPCalculatedField
    public var offsetX: Double
    public var offsetY: Double
    public var fontSize: StudioWIPTextOverride
    public var color: StudioWIPColorOverride
    public var opacity: StudioWIPTextOverride

    public init(
        position: StudioWIPZonePosition,
        enabled: Bool = false,
        prefix: String = "",
        calculatedField: StudioWIPCalculatedField = .none,
        offsetX: Double = 0,
        offsetY: Double = 0,
        fontSize: StudioWIPTextOverride = .init(value: 0.028),
        color: StudioWIPColorOverride = .init(value: .init(red: 1, green: 1, blue: 1)),
        opacity: StudioWIPTextOverride = .init()
    ) {
        self.position = position
        self.enabled = enabled
        self.prefix = prefix
        self.calculatedField = calculatedField
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.fontSize = fontSize
        self.color = color
        self.opacity = opacity
    }

    public func resolvedText(frame: Int, timecode: String, date: String, outputFilename: String) -> String {
        let calculated = switch calculatedField {
        case .none: ""
        case .frameRelative: String(frame)
        case .frame: String(frame)
        case .timecode: timecode
        case .date: date
        case .outputFilename: outputFilename
        }
        return prefix + calculated
    }

    public func validate() throws {
        guard [offsetX, offsetY, fontSize.value, opacity.value].allSatisfy(\.isFinite),
              (-1 ... 1).contains(offsetX), (-1 ... 1).contains(offsetY),
              !fontSize.enabled || (0.001 ... 1).contains(fontSize.value),
              !opacity.enabled || (0 ... 1).contains(opacity.value) else {
            throw StudioWIPReviewContractError.invalidZone(position)
        }
        try color.value.validate()
    }
}

public struct StudioWIPReviewPreset: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var outputColorSpace: StudioWIPOutputColorSpace
    public var reviewRaster: StudioWIPReviewRaster
    public var customWidth: Int?
    public var customHeight: Int?
    public var placement: StudioWIPPlacement
    public var resampleFilter: StudioWIPResampleFilter
    public var canvasColor: StudioReviewColor
    public var blankingEnabled: Bool
    public var blankingAspect: StudioWIPBlankingAspect
    public var customBlankingAspect: Double?
    public var blankingColor: StudioReviewColor
    public var blankingOpacity: Double
    public var fontFamily: String
    public var fontStyle: StudioWIPFontStyle
    public var fontSize: Double
    public var textColor: StudioReviewColor
    public var textOpacity: Double
    public var graphicsWhiteMode: StudioWIPGraphicsWhiteMode
    public var graphicsWhiteNits: Double
    public var hlgPeakNits: Double
    public var outlineEnabled: Bool
    public var outlineWidth: Double
    public var outlineColor: StudioReviewColor
    public var outlineOpacity: Double
    public var shadowEnabled: Bool
    public var shadowOffsetX: Double
    public var shadowOffsetY: Double
    public var shadowSoftness: Double
    public var shadowColor: StudioReviewColor
    public var shadowOpacity: Double
    public var paddingLeft: Double
    public var paddingRight: Double
    public var paddingTop: Double
    public var paddingBottom: Double
    public var frameRelativeBase: Int
    public var frameStart: Int
    public var frameRateMode: StudioWIPFrameRateMode
    public var frameRateOverride: Double
    public var timecodeStart: String
    public var reviewDate: String
    public var zones: [StudioWIPReviewZone]

    public init(
        id: UUID,
        name: String,
        outputColorSpace: StudioWIPOutputColorSpace = .rec709Gamma24,
        reviewRaster: StudioWIPReviewRaster = .output,
        customWidth: Int? = nil,
        customHeight: Int? = nil,
        placement: StudioWIPPlacement = .fit,
        resampleFilter: StudioWIPResampleFilter = .lanczos,
        canvasColor: StudioReviewColor = .init(red: 0, green: 0, blue: 0),
        blankingEnabled: Bool = false,
        blankingAspect: StudioWIPBlankingAspect = .ratio239,
        customBlankingAspect: Double? = nil,
        blankingColor: StudioReviewColor = .init(red: 0, green: 0, blue: 0),
        blankingOpacity: Double = 1,
        fontFamily: String = "Helvetica Neue",
        fontStyle: StudioWIPFontStyle = .regular,
        fontSize: Double = 0.028,
        textColor: StudioReviewColor = .init(red: 1, green: 1, blue: 1),
        textOpacity: Double = 1,
        graphicsWhiteMode: StudioWIPGraphicsWhiteMode = .automatic,
        graphicsWhiteNits: Double = 203,
        hlgPeakNits: Double = 1_000,
        outlineEnabled: Bool = true,
        outlineWidth: Double = 0.001,
        outlineColor: StudioReviewColor = .init(red: 0, green: 0, blue: 0),
        outlineOpacity: Double = 1,
        shadowEnabled: Bool = false,
        shadowOffsetX: Double = 0.0015,
        shadowOffsetY: Double = 0.002,
        shadowSoftness: Double = 0.002,
        shadowColor: StudioReviewColor = .init(red: 0, green: 0, blue: 0),
        shadowOpacity: Double = 0.60,
        paddingLeft: Double = 0.015,
        paddingRight: Double = 0.015,
        paddingTop: Double = 0.020,
        paddingBottom: Double = 0.020,
        frameRelativeBase: Int = 1,
        frameStart: Int = 1_001,
        frameRateMode: StudioWIPFrameRateMode = .render,
        frameRateOverride: Double = 24,
        timecodeStart: String = "00:00:00:00",
        reviewDate: String = "",
        zones: [StudioWIPReviewZone] = StudioWIPZonePosition.allCases.map { .init(position: $0) }
    ) {
        self.id = id; self.name = name; self.outputColorSpace = outputColorSpace
        self.reviewRaster = reviewRaster; self.customWidth = customWidth; self.customHeight = customHeight
        self.placement = placement; self.resampleFilter = resampleFilter; self.canvasColor = canvasColor
        self.blankingEnabled = blankingEnabled; self.blankingAspect = blankingAspect
        self.customBlankingAspect = customBlankingAspect; self.blankingColor = blankingColor
        self.blankingOpacity = blankingOpacity; self.fontFamily = fontFamily; self.fontStyle = fontStyle
        self.fontSize = fontSize; self.textColor = textColor; self.textOpacity = textOpacity
        self.graphicsWhiteMode = graphicsWhiteMode; self.graphicsWhiteNits = graphicsWhiteNits
        self.hlgPeakNits = hlgPeakNits; self.outlineEnabled = outlineEnabled
        self.outlineWidth = outlineWidth; self.outlineColor = outlineColor; self.outlineOpacity = outlineOpacity
        self.shadowEnabled = shadowEnabled; self.shadowOffsetX = shadowOffsetX; self.shadowOffsetY = shadowOffsetY
        self.shadowSoftness = shadowSoftness; self.shadowColor = shadowColor; self.shadowOpacity = shadowOpacity
        self.paddingLeft = paddingLeft; self.paddingRight = paddingRight; self.paddingTop = paddingTop
        self.paddingBottom = paddingBottom; self.frameRelativeBase = frameRelativeBase; self.frameStart = frameStart
        self.frameRateMode = frameRateMode; self.frameRateOverride = frameRateOverride
        self.timecodeStart = timecodeStart; self.reviewDate = reviewDate; self.zones = zones
    }

    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !fontFamily.isEmpty, fontSize.isFinite, (0.001 ... 1).contains(fontSize),
              graphicsWhiteNits.isFinite, (1 ... 10_000).contains(graphicsWhiteNits),
              hlgPeakNits.isFinite, (100 ... 10_000).contains(hlgPeakNits),
              [blankingOpacity, textOpacity, outlineOpacity, shadowOpacity].allSatisfy({ $0.isFinite && (0 ... 1).contains($0) }),
              [outlineWidth, shadowOffsetX, shadowOffsetY, shadowSoftness, paddingLeft, paddingRight, paddingTop, paddingBottom].allSatisfy(\.isFinite),
              (0 ... 0.010).contains(outlineWidth),
              (-0.05 ... 0.05).contains(shadowOffsetX),
              (-0.05 ... 0.05).contains(shadowOffsetY),
              (0 ... 0.05).contains(shadowSoftness),
              [paddingLeft, paddingRight, paddingTop, paddingBottom].allSatisfy({ (0 ... 1).contains($0) }),
              frameRateOverride.isFinite, (1 ... 240).contains(frameRateOverride),
              !timecodeStart.isEmpty else { throw StudioWIPReviewContractError.invalidPreset }
        if reviewRaster == .custom {
            guard let customWidth, let customHeight,
                  (1 ... 32_768).contains(customWidth),
                  (1 ... 32_768).contains(customHeight) else {
                throw StudioWIPReviewContractError.invalidRaster
            }
        } else if customWidth != nil || customHeight != nil {
            throw StudioWIPReviewContractError.invalidRaster
        }
        if blankingAspect == .custom {
            guard let customBlankingAspect, customBlankingAspect.isFinite,
                  (0.1 ... 10).contains(customBlankingAspect) else {
                throw StudioWIPReviewContractError.invalidBlanking
            }
        } else if customBlankingAspect != nil {
            throw StudioWIPReviewContractError.invalidBlanking
        }
        guard zones.count == StudioWIPZonePosition.allCases.count,
              Set(zones.map(\.position)) == Set(StudioWIPZonePosition.allCases) else {
            throw StudioWIPReviewContractError.invalidZones
        }
        try canvasColor.validate(); try blankingColor.validate(); try textColor.validate()
        try outlineColor.validate(); try shadowColor.validate(); try zones.forEach { try $0.validate() }
    }

    public static let builtIns: [Self] = [
        .init(id: UUID(uuidString: "913B66F2-3CAA-40D5-B123-82BE4BDF0101")!, name: "Editorial · Rec.709", zones: editorialZones),
        .init(id: UUID(uuidString: "913B66F2-3CAA-40D5-B123-82BE4BDF0102")!, name: "Editorial 2.39 · Rec.709", blankingEnabled: true, zones: editorialZones),
        .init(id: UUID(uuidString: "913B66F2-3CAA-40D5-B123-82BE4BDF0103")!, name: "Editorial · Rec.2100 PQ", outputColorSpace: .rec2100PQ, zones: editorialZones),
        .init(id: UUID(uuidString: "913B66F2-3CAA-40D5-B123-82BE4BDF0104")!, name: "Editorial · Rec.2100 HLG", outputColorSpace: .rec2100HLG, zones: editorialZones),
    ]

    private static var editorialZones: [StudioWIPReviewZone] {
        StudioWIPZonePosition.allCases.map { position in
            switch position {
            case .topLeft: .init(position: position, enabled: true, prefix: "", calculatedField: .outputFilename)
            case .topRight: .init(position: position, enabled: true, prefix: "Frame ", calculatedField: .frame)
            case .bottomLeft: .init(position: position, enabled: true, prefix: "", calculatedField: .date)
            case .bottomRight: .init(position: position, enabled: true, prefix: "", calculatedField: .timecode)
            default: .init(position: position)
            }
        }
    }
}

public enum StudioWIPReviewContractError: Error, LocalizedError, Equatable {
    case invalidPreset, invalidColor, invalidRaster, invalidBlanking, invalidZones
    case invalidZone(StudioWIPZonePosition)
    public var errorDescription: String? {
        switch self {
        case .invalidPreset: "El preset WIP Review contiene valores no válidos."
        case .invalidColor: "Un color WIP Review no es RGBA finito entre 0 y 1."
        case .invalidRaster: "El raster personalizado WIP Review requiere ancho y alto positivos."
        case .invalidBlanking: "El aspect ratio personalizado WIP Review debe ser positivo."
        case .invalidZones: "WIP Review requiere exactamente sus seis zonas identificadas."
        case let .invalidZone(zone): "La zona WIP Review \(zone.rawValue) contiene valores no válidos."
        }
    }
}
