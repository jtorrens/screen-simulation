@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import ScreenPhysicalBridge
import StudioMedia

struct DecodedNativeFrame: Sendable {
    let width: Int
    let height: Int
    let rgba: [Float]
    let sourceDescription: String
}

enum NativeMediaError: Error, LocalizedError {
    case unsupportedType(String)
    case unreadable(String)
    case invalidRaster

    var errorDescription: String? {
        switch self {
        case let .unsupportedType(value): "Formato no compatible: \(value)."
        case let .unreadable(value): "No se puede decodificar \(value)."
        case .invalidRaster: "El frame decodificado no tiene un raster RGB válido."
        }
    }
}

enum NativeMediaDecoder {
    private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    static func decode(url: URL, time: CMTime) async throws -> DecodedNativeFrame {
        if videoExtensions.contains(url.pathExtension.lowercased()) {
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let result = try await generator.image(at: time)
            return try decode(
                image: result.image,
                description: "\(url.lastPathComponent) · \(result.actualTime.seconds.formatted(.number.precision(.fractionLength(3)))) s"
            )
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw NativeMediaError.unreadable(url.lastPathComponent) }
        return try decode(image: image, description: url.lastPathComponent)
    }

    static func decode(image: CGImage, description: String) throws -> DecodedNativeFrame {
        guard image.width > 0, image.height > 0,
              let colorSpace = image.colorSpace,
              colorSpace.model == .rgb
        else { throw NativeMediaError.invalidRaster }
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let rendered = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard let context = CGContext(
                data: storage.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard rendered else { throw NativeMediaError.invalidRaster }
        return DecodedNativeFrame(
            width: image.width,
            height: image.height,
            rgba: bytes.map { Float($0) / 255 },
            sourceDescription: description
        )
    }
}

enum SyntheticPattern: UInt32, Codable, CaseIterable, Identifiable, Sendable {
    case animatedCheckerboard = 0
    case eyeChart = 1
    case editorialTextReference = 2
    case cameraColorReference = 3
    case frequencyMoireReference = 4
    case photometricDeviceScale = 5
    case vfxComparisonReference = 6

    var id: UInt32 { rawValue }

    var label: String {
        switch self {
        case .animatedCheckerboard: "Checker animado"
        case .eyeChart: "Carta E"
        case .editorialTextReference: "Referencia editorial 4K"
        case .cameraColorReference: "Referencia color cámara 4K"
        case .frequencyMoireReference: "Frecuencia / moiré 4K"
        case .photometricDeviceScale: "Escala fotométrica"
        case .vfxComparisonReference: "Referencia VFX fotografiada"
        }
    }

    var sourceDetection: StudioMediaDetection {
        StudioMediaDetection(
            proposedInputTransformID: "srgb-encoded-rec709",
            inputTransformProvenance: .proposed,
            matrix: .bt709,
            matrixProvenance: .proposed,
            range: .full,
            rangeProvenance: .proposed,
            colorModel: .rgb,
            colorModelProvenance: .proposed,
            hasAlpha: false,
            alpha: .ignore,
            alphaProvenance: .proposed
        )
    }

    func frame(time: Double = 0) throws -> DecodedNativeFrame {
        var width: UInt32 = 0
        var height: UInt32 = 0
        guard screen_test_pattern_dimensions(rawValue, &width, &height) else {
            throw NativeMediaError.invalidRaster
        }
        var rgba = [Float](repeating: 0, count: Int(width * height) * 4)
        var message: UnsafePointer<CChar>?
        let succeeded = rgba.withUnsafeMutableBufferPointer {
            screen_test_pattern_render_rgba32f(
                rawValue,
                time,
                $0.baseAddress,
                Int(width * height),
                &message
            )
        }
        guard succeeded else {
            throw NativeMediaError.unreadable(
                message.map(String.init(cString:)) ?? label
            )
        }
        return DecodedNativeFrame(
            width: Int(width),
            height: Int(height),
            rgba: rgba,
            sourceDescription: label
        )
    }
}
