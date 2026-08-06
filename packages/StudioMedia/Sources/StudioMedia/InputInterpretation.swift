@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ImageIO

public enum StudioSignalMatrix: String, Codable, CaseIterable, Identifiable, Sendable {
    case bt601, bt709, bt2020
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .bt601: "BT.601"
        case .bt709: "BT.709"
        case .bt2020: "BT.2020 NCL"
        }
    }
}

public enum StudioSignalRange: String, Codable, CaseIterable, Identifiable, Sendable {
    case video, full
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .video: "Video / limitada"
        case .full: "Completa"
        }
    }
}

public enum StudioAlphaMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case straight, premultiplied, ignore
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .straight: "Straight"
        case .premultiplied: "Premultiplied"
        case .ignore: "Ignore / Opaque"
        }
    }
}

public enum StudioMetadataProvenance: String, Codable, Sendable {
    case detected
    case proposed
    case defaulted

    public var feminineLabel: String {
        switch self {
        case .detected: "Detectada"
        case .proposed: "Propuesta"
        case .defaulted: "Predeterminada"
        }
    }

    public var masculineLabel: String {
        switch self {
        case .detected: "Detectado"
        case .proposed: "Propuesto"
        case .defaulted: "Predeterminado"
        }
    }
}

public struct StudioInputTransformProposal: Equatable, Sendable {
    public let id: String
    public let provenance: StudioMetadataProvenance

    public init(id: String, provenance: StudioMetadataProvenance) {
        self.id = id
        self.provenance = provenance
    }
}

public struct StudioMediaDetection: Equatable, Sendable {
    public var proposedInputTransformID: String?
    public var inputTransformProvenance: StudioMetadataProvenance?
    public var matrix: StudioSignalMatrix?
    public var matrixProvenance: StudioMetadataProvenance?
    public var range: StudioSignalRange?
    public var rangeProvenance: StudioMetadataProvenance?
    public var hasAlpha: Bool
    public var alpha: StudioAlphaMode?
    public var alphaProvenance: StudioMetadataProvenance?
    public var declaredPrimaries: String?
    public var declaredTransfer: String?
    public var declaredMatrix: String?
    public var note: String?

    public init(
        proposedInputTransformID: String? = nil,
        inputTransformProvenance: StudioMetadataProvenance? = nil,
        matrix: StudioSignalMatrix? = nil,
        matrixProvenance: StudioMetadataProvenance? = nil,
        range: StudioSignalRange? = nil,
        rangeProvenance: StudioMetadataProvenance? = nil,
        hasAlpha: Bool = false,
        alpha: StudioAlphaMode? = nil,
        alphaProvenance: StudioMetadataProvenance? = nil,
        declaredPrimaries: String? = nil,
        declaredTransfer: String? = nil,
        declaredMatrix: String? = nil,
        note: String? = nil
    ) {
        self.proposedInputTransformID = proposedInputTransformID
        self.inputTransformProvenance = inputTransformProvenance
        self.matrix = matrix
        self.matrixProvenance = matrixProvenance
        self.range = range
        self.rangeProvenance = rangeProvenance
        self.hasAlpha = hasAlpha
        self.alpha = alpha
        self.alphaProvenance = alphaProvenance
        self.declaredPrimaries = declaredPrimaries
        self.declaredTransfer = declaredTransfer
        self.declaredMatrix = declaredMatrix
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

    public static func proposedInputTransformID(
        primaries: String?, transfer: String?, matrix: String?
    ) -> String? {
        inputTransformProposal(
            primaries: primaries, transfer: transfer, matrix: matrix
        )?.id
    }

    public static func inputTransformProposal(
        primaries: String?, transfer: String?, matrix: String?
    ) -> StudioInputTransformProposal? {
        let primaries = primaries?.lowercased() ?? ""
        let transfer = transfer?.lowercased() ?? ""
        let matrix = matrix?.lowercased() ?? ""
        let has2020Primaries = primaries.contains("2020")
        let has2020Matrix = matrix.contains("2020")
        let hasPQ = transfer.contains("2084") || transfer.contains("pq")
        if has2020Primaries, has2020Matrix, hasPQ {
            return .init(
                id: "display-rec2100-pq-aces2-hdr-1000",
                provenance: .detected
            )
        }
        let has709Primaries = primaries.contains("709")
        let has709Matrix = matrix.contains("709")
        let has709Transfer = transfer.contains("709")
            || transfer.contains("1886") || transfer.contains("gamma 2.4")
        if has709Primaries, has709Matrix {
            return .init(
                id: "display-rec709-aces2-sdr",
                provenance: has709Transfer ? .detected : .proposed
            )
        }
        if primaries.contains("srgb") || primaries.contains("s-rgb")
            || transfer.contains("srgb") || transfer.contains("s-rgb") {
            return .init(
                id: "display-srgb-aces2-sdr",
                provenance: .detected
            )
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
        let proposal = inputTransformProposal(
            primaries: primaries, transfer: transfer, matrix: ycbcr
        )
        return StudioMediaDetection(
            proposedInputTransformID: proposal?.id,
            inputTransformProvenance: proposal?.provenance,
            matrix: proposedMatrix(ycbcr),
            matrixProvenance: ycbcr == nil ? nil : .detected,
            range: range,
            rangeProvenance: range == nil ? nil : .detected,
            hasAlpha: hasAlpha,
            alpha: alpha,
            alphaProvenance: alpha == nil ? nil : .detected,
            declaredPrimaries: primaries,
            declaredTransfer: transfer,
            declaredMatrix: ycbcr
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
            ? "display-srgb-aces2-sdr" : nil
        return StudioMediaDetection(
            proposedInputTransformID: input,
            inputTransformProvenance: input == nil ? nil : .detected,
            range: .full,
            rangeProvenance: .detected,
            hasAlpha: hasAlpha,
            alpha: hasAlpha && sourceType == "public.png" ? .straight : (hasAlpha ? nil : .ignore),
            alphaProvenance: hasAlpha && sourceType != "public.png" ? nil : .detected,
            declaredPrimaries: profile
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
