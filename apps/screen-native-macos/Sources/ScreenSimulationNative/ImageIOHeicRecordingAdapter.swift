import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Platform binding for one already-resolved opaque HEIC still request.
///
/// Profile selection, output colorimetry and quality remain upstream authorities. This adapter
/// only executes one ImageIO encode/decode round trip and reports the exact payload evidence.
struct ImageIOHeicStillRequest: Equatable, Sendable {
    enum ColorSpace: String, Sendable {
        case displayP3D65
        case rec709
    }

    let profileID: String
    let width: Int
    let height: Int
    let quality: Double
    let colorSpace: ColorSpace
    let rgba8: [UInt8]

    func validated() throws -> Self {
        let pixels = width.multipliedReportingOverflow(by: height)
        let components = pixels.partialValue.multipliedReportingOverflow(by: 4)
        guard !profileID.isEmpty,
              width > 0, height > 0,
              quality.isFinite, (0 ... 1).contains(quality),
              !pixels.overflow, !components.overflow,
              rgba8.count == components.partialValue
        else { throw ImageIOHeicRecordingError.invalidRequest }
        for alpha in stride(from: 3, to: rgba8.count, by: 4) where rgba8[alpha] != 255 {
            throw ImageIOHeicRecordingError.nonOpaqueInput
        }
        return self
    }
}

struct ImageIOHeicStillResult: Equatable, Sendable {
    let profileID: String
    let width: Int
    let height: Int
    let rgba8: [UInt8]
    let encodedData: Data
    let encodedBytes: Int
    let encodedSHA256: [UInt8]
}

enum ImageIOHeicRecordingError: Error, Equatable {
    case invalidRequest
    case nonOpaqueInput
    case unavailableEncoder
    case encodeFailed
    case decodeFailed
    case decodedRasterMismatch
}

enum ImageIOHeicRecordingAdapter {
    static func roundTrip(_ unresolved: ImageIOHeicStillRequest) throws -> ImageIOHeicStillResult {
        let request = try unresolved.validated()
        let colorSpace = try cgColorSpace(request.colorSpace)
        let encoded = try encode(request, colorSpace: colorSpace)
        let decoded = try decode(
            encoded,
            width: request.width,
            height: request.height,
            colorSpace: colorSpace
        )
        return ImageIOHeicStillResult(
            profileID: request.profileID,
            width: request.width,
            height: request.height,
            rgba8: decoded,
            encodedData: encoded,
            encodedBytes: encoded.count,
            encodedSHA256: Array(SHA256.hash(data: encoded))
        )
    }

    private static func encode(
        _ request: ImageIOHeicStillRequest,
        colorSpace: CGColorSpace
    ) throws -> Data {
        let destinationTypes = CGImageDestinationCopyTypeIdentifiers() as NSArray
        guard destinationTypes.contains(UTType.heic.identifier)
        else { throw ImageIOHeicRecordingError.unavailableEncoder }
        let provider = CGDataProvider(data: Data(request.rgba8) as CFData)
        guard let provider,
              let image = CGImage(
                width: request.width,
                height: request.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: request.width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
                    .union(.byteOrder32Big),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .relativeColorimetric
              )
        else { throw ImageIOHeicRecordingError.invalidRequest }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.heic.identifier as CFString,
            1,
            nil
        ) else { throw ImageIOHeicRecordingError.unavailableEncoder }
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: request.quality,
            kCGImagePropertyHasAlpha: false,
            kCGImagePropertyOrientation: 1,
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageIOHeicRecordingError.encodeFailed
        }
        return output as Data
    }

    private static func decode(
        _ encoded: Data,
        width: Int,
        height: Int,
        colorSpace: CGColorSpace
    ) throws -> [UInt8] {
        guard let source = CGImageSourceCreateWithData(encoded as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let image = CGImageSourceCreateImageAtIndex(
                source,
                0,
                [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
              )
        else { throw ImageIOHeicRecordingError.decodeFailed }
        guard image.width == width, image.height == height else {
            throw ImageIOHeicRecordingError.decodedRasterMismatch
        }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let created = rgba.withUnsafeMutableBytes { storage in
            guard let context = CGContext(
                data: storage.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
                    .union(.byteOrder32Big).rawValue
            ) else { return false }
            context.interpolationQuality = .none
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard created else { throw ImageIOHeicRecordingError.decodeFailed }
        for alpha in stride(from: 3, to: rgba.count, by: 4) {
            rgba[alpha] = 255
        }
        return rgba
    }

    private static func cgColorSpace(
        _ colorSpace: ImageIOHeicStillRequest.ColorSpace
    ) throws -> CGColorSpace {
        let name: CFString = switch colorSpace {
        case .displayP3D65: CGColorSpace.displayP3
        case .rec709: CGColorSpace.itur_709
        }
        guard let resolved = CGColorSpace(name: name) else {
            throw ImageIOHeicRecordingError.invalidRequest
        }
        return resolved
    }
}
