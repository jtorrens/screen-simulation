@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO

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

enum SyntheticPattern: String, CaseIterable, Identifiable {
    case colorAndRange
    case checkerboard
    case frequency

    var id: String { rawValue }

    var label: String {
        switch self {
        case .colorAndRange: "Color / negativos / >1"
        case .checkerboard: "Checker animado"
        case .frequency: "Frecuencia RGB"
        }
    }

    func frame(width: Int = 960, height: Int = 540, phase: Int = 0) -> DecodedNativeFrame {
        var rgba = [Float](repeating: 0, count: width * height * 4)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let offset = (y * width + x) * 4
                let u = Float(x) / Float(max(width - 1, 1))
                let v = Float(y) / Float(max(height - 1, 1))
                let rgb: SIMD3<Float>
                switch self {
                case .colorAndRange:
                    rgb = SIMD3(u * 2.5 - 0.25, v * 1.5 - 0.1, (1 - u) * 4)
                case .checkerboard:
                    let code: Float = ((x / 48 + y / 48 + phase) % 2 == 0) ? 0.08 : 1.25
                    rgb = SIMD3(code, code * (0.5 + 0.5 * u), code * (0.5 + 0.5 * v))
                case .frequency:
                    rgb = SIMD3(
                        (x / max(1, 2 + y / 24)).isMultiple(of: 2) ? 1 : 0,
                        (x / max(1, 4 + y / 16)).isMultiple(of: 2) ? 1 : 0,
                        (x / max(1, 8 + y / 8)).isMultiple(of: 2) ? 1 : 0
                    )
                }
                rgba[offset] = rgb.x
                rgba[offset + 1] = rgb.y
                rgba[offset + 2] = rgb.z
                rgba[offset + 3] = 1
            }
        }
        return DecodedNativeFrame(
            width: width,
            height: height,
            rgba: rgba,
            sourceDescription: label
        )
    }
}

