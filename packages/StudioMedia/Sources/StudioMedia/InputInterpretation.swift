@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ImageIO

public enum StudioSignalMatrix: String, CaseIterable, Identifiable, Sendable {
    case auto, bt601, bt709, bt2020
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .auto: "Auto"
        case .bt601: "BT.601"
        case .bt709: "BT.709"
        case .bt2020: "BT.2020 NCL"
        }
    }
}

public enum StudioSignalRange: String, CaseIterable, Identifiable, Sendable {
    case auto, video, full
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .auto: "Auto"
        case .video: "Video / limitada"
        case .full: "Completa"
        }
    }
}

public enum StudioAlphaMode: String, CaseIterable, Identifiable, Sendable {
    case auto, straight, premultiplied, ignore
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .auto: "Auto"
        case .straight: "Straight"
        case .premultiplied: "Premultiplied"
        case .ignore: "Ignore / Opaque"
        }
    }
}

public struct StudioMediaDetection: Equatable, Sendable {
    public var proposedInputColorSpace: String?
    public var matrix: StudioSignalMatrix?
    public var range: StudioSignalRange?
    public var hasAlpha: Bool
    public var alpha: StudioAlphaMode?
    public var note: String?

    public init(
        proposedInputColorSpace: String? = nil,
        matrix: StudioSignalMatrix? = nil,
        range: StudioSignalRange? = nil,
        hasAlpha: Bool = false,
        alpha: StudioAlphaMode? = nil,
        note: String? = nil
    ) {
        self.proposedInputColorSpace = proposedInputColorSpace
        self.matrix = matrix
        self.range = range
        self.hasAlpha = hasAlpha
        self.alpha = alpha
        self.note = note
    }
}

/// Extracted from CREDITOS-HDR's metadata detector; absence or malformed metadata
/// produces a partial proposal and never prevents media from opening.
public enum StudioMediaMetadataDetector {
    public static func detect(url: URL, isVideo: Bool) async -> StudioMediaDetection {
        do {
            return isVideo ? try await detectVideo(url) : try detectImage(url)
        } catch {
            return StudioMediaDetection(note: error.localizedDescription)
        }
    }

    public static func proposedInputColorSpace(
        primaries: String?, transfer: String?, matrix: String?
    ) -> String? {
        let value = [primaries, transfer, matrix]
            .compactMap { $0?.lowercased() }.joined(separator: " ")
        if value.contains("2020") && (value.contains("2084") || value.contains("pq")) {
            return "Rec.2100 ST2084"
        }
        if value.contains("709") { return "Input - Rec.709" }
        if value.contains("srgb") || value.contains("s-rgb") {
            return "sRGB Encoded Rec.709 (sRGB)"
        }
        return nil
    }

    public static func proposedMatrix(_ value: String?) -> StudioSignalMatrix? {
        let value = value?.lowercased() ?? ""
        if value.contains("2020") { return .bt2020 }
        if value.contains("709") { return .bt709 }
        if value.contains("601") || value.contains("170m") || value.contains("470") { return .bt601 }
        return nil
    }

    private static func detectVideo(_ url: URL) async throws -> StudioMediaDetection {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              let description = try await track.load(.formatDescriptions).first
        else { throw DetectionError.missingVideoTrack }
        let extensions = (CMFormatDescriptionGetExtensions(description) as NSDictionary?) ?? [:]
        let primaries = text(extensions[kCMFormatDescriptionExtension_ColorPrimaries])
        let transfer = text(extensions[kCMFormatDescriptionExtension_TransferFunction])
        let ycbcr = text(extensions[kCMFormatDescriptionExtension_YCbCrMatrix])
        let hasAlpha = (extensions[kCMFormatDescriptionExtension_ContainsAlphaChannel] as? NSNumber)?.boolValue ?? false
        let alphaDescription = text(extensions[kCMFormatDescriptionExtension_AlphaChannelMode])?.lowercased() ?? ""
        let alpha: StudioAlphaMode? = if !hasAlpha { .ignore }
            else if alphaDescription.contains("premultiplied") { .premultiplied }
            else if alphaDescription.contains("straight") { .straight }
            else { nil }
        let subtype = CMFormatDescriptionGetMediaSubType(description)
        let range: StudioSignalRange? = switch subtype {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarFullRange: .full
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
             kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange: .video
        default: nil
        }
        return StudioMediaDetection(
            proposedInputColorSpace: proposedInputColorSpace(
                primaries: primaries, transfer: transfer, matrix: ycbcr
            ),
            matrix: proposedMatrix(ycbcr),
            range: range,
            hasAlpha: hasAlpha,
            alpha: alpha
        )
    }

    private static func detectImage(_ url: URL) throws -> StudioMediaDetection {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { throw DetectionError.unreadableImage }
        let profile = properties[kCGImagePropertyProfileName] as? String
        let model = properties[kCGImagePropertyColorModel] as? String
        let hasAlpha = (properties[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue ?? false
        let sourceType = CGImageSourceGetType(source) as String?
        let description = [profile, model].compactMap { $0?.lowercased() }.joined(separator: " ")
        let input = description.contains("srgb")
            ? "sRGB Encoded Rec.709 (sRGB)" : nil
        return StudioMediaDetection(
            proposedInputColorSpace: input,
            range: .full,
            hasAlpha: hasAlpha,
            alpha: hasAlpha && sourceType == "public.png" ? .straight : (hasAlpha ? nil : .ignore)
        )
    }

    private static func text(_ value: Any?) -> String? {
        value.map { String(describing: $0) }
    }
}

private enum DetectionError: Error, LocalizedError {
    case missingVideoTrack, unreadableImage
    var errorDescription: String? {
        switch self {
        case .missingVideoTrack: "No hay una pista de vídeo con metadata legible."
        case .unreadableImage: "No se puede leer la metadata de la imagen."
        }
    }
}
