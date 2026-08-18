@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
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

typealias ExactFrameRate = StudioFrameRate

struct NativeVideoTimelineInfo: Sendable, Equatable {
    let exactFrameRate: ExactFrameRate
    let frameCount: Int

    var frameRate: Double { exactFrameRate.framesPerSecond }
}

enum NativeMediaError: Error, LocalizedError {
    case unsupportedType(String)
    case unreadable(String)
    case invalidRaster
    case invalidFrameRate

    var errorDescription: String? {
        switch self {
        case let .unsupportedType(value): "Formato no compatible: \(value)."
        case let .unreadable(value): "No se puede decodificar \(value)."
        case .invalidRaster: "El frame decodificado no tiene un raster RGB válido."
        case .invalidFrameRate: "La cadencia del medio no es una fracción positiva válida."
        }
    }
}

struct NativeFFmpegVideoInfo: Sendable {
    let width: Int
    let height: Int
    let exactFrameRate: ExactFrameRate
    let duration: CMTime
    let frameCount: Int
    let hasAlpha: Bool
}

enum NativeFFmpegMedia {
    private static let abiVersion = UInt32(SCREEN_FFMPEG_MEDIA_ABI_VERSION)

    static func probe(url: URL) throws -> NativeFFmpegVideoInfo {
        var info = ScreenFfmpegMediaInfoV1()
        var message: UnsafePointer<CChar>?
        let succeeded = url.withUnsafeFileSystemRepresentation { path in
            screen_ffmpeg_probe_media_v1(path, &info, &message)
        }
        guard succeeded,
              info.abi_version == abiVersion,
              info.width > 0, info.height > 0,
              info.frame_rate_numerator > 0, info.frame_rate_denominator > 0,
              info.has_duration, info.duration_denominator > 0
        else {
            throw NativeMediaError.unreadable(
                message.map(String.init(cString:)) ?? url.lastPathComponent
            )
        }
        let frameRate = try ExactFrameRate(
            numerator: info.frame_rate_numerator,
            denominator: info.frame_rate_denominator
        )
        let duration = CMTime(
            value: CMTimeValue(info.duration_numerator),
            timescale: CMTimeScale(info.duration_denominator)
        )
        guard duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 else {
            throw NativeMediaError.invalidFrameRate
        }
        return NativeFFmpegVideoInfo(
            width: Int(info.width), height: Int(info.height),
            exactFrameRate: frameRate,
            duration: duration,
            frameCount: max(1, Int((duration.seconds * frameRate.framesPerSecond).rounded())),
            hasAlpha: info.has_alpha
        )
    }

    static func decode(
        url: URL,
        time: CMTime,
        colorModel: StudioSignalColorModel,
        matrix: StudioSignalMatrix,
        range: StudioSignalRange
    ) throws -> DecodedNativeFrame {
        guard time.isNumeric, time.timescale > 0 else { throw NativeMediaError.invalidFrameRate }
        var frame = ScreenFfmpegDecodedFrameV1()
        var message: UnsafePointer<CChar>?
        let succeeded = url.withUnsafeFileSystemRepresentation { path in
            screen_ffmpeg_decode_frame_v1(
                path,
                time.value,
                UInt32(time.timescale),
                0, // Exact is the authored source-sampling policy for this host request.
                colorModel == .rgb ? 0 : 1,
                matrix == .bt601 ? 0 : (matrix == .bt709 ? 1 : 2),
                range == .video ? 0 : 1,
                &frame,
                &message
            )
        }
        defer {
            if let pixels = frame.pixels_rgba {
                screen_ffmpeg_free_rgba_float_v1(pixels, frame.width, frame.height)
            }
        }
        guard succeeded,
              frame.width > 0, frame.height > 0,
              frame.timestamp_denominator > 0,
              let pixels = frame.pixels_rgba
        else {
            throw NativeMediaError.unreadable(
                message.map(String.init(cString:)) ?? "frame \(time.seconds)"
            )
        }
        let count = Int(frame.width) * Int(frame.height) * 4
        let rgba = Array(UnsafeBufferPointer(start: pixels, count: count))
        guard rgba.allSatisfy(\.isFinite) else {
            throw NativeMediaError.unreadable("FFmpeg devolvió muestras no finitas")
        }
        return DecodedNativeFrame(
            width: Int(frame.width), height: Int(frame.height), rgba: rgba,
            sourceDescription: "\(url.lastPathComponent) · \(Double(frame.timestamp_numerator) / Double(frame.timestamp_denominator)) s"
        )
    }
}

enum NativeMediaDecoder {
    private static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]

    static func decode(url: URL, time: CMTime) async throws -> DecodedNativeFrame {
        if url.pathExtension.lowercased() == "exr" {
            return try decodeOpenEXR(url)
        }
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

    static func videoTimelineInfo(url: URL) async throws -> NativeVideoTimelineInfo? {
        guard videoExtensions.contains(url.pathExtension.lowercased()) else { return nil }
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let track = try await asset.loadTracks(withMediaType: .video).first
        guard let track, duration.isNumeric, duration.seconds.isFinite, duration.seconds > 0 else {
            throw NativeMediaError.unreadable(url.lastPathComponent)
        }
        let minimumFrameDuration = try await track.load(.minFrameDuration)
        guard minimumFrameDuration.isNumeric,
              minimumFrameDuration.value > 0,
              minimumFrameDuration.timescale > 0,
              let numerator = UInt32(exactly: minimumFrameDuration.timescale),
              let denominator = UInt32(exactly: minimumFrameDuration.value)
        else { throw NativeMediaError.invalidFrameRate }
        let exactFrameRate = try ExactFrameRate(
            numerator: numerator,
            denominator: denominator
        )
        let frameRate = exactFrameRate.framesPerSecond
        return NativeVideoTimelineInfo(
            exactFrameRate: exactFrameRate,
            frameCount: max(1, Int((duration.seconds * frameRate).rounded()))
        )
    }

    private static func decodeOpenEXR(_ url: URL) throws -> DecodedNativeFrame {
        var pixels: UnsafeMutablePointer<Float>?
        var width: UInt32 = 0
        var height: UInt32 = 0
        var declaredColorSpace: UnsafeMutablePointer<CChar>?
        var message: UnsafeMutablePointer<CChar>?
        let succeeded = url.withUnsafeFileSystemRepresentation { path in
            screen_openexr_decode_rgba_float(
                path, &pixels, &width, &height, &declaredColorSpace, &message
            )
        }
        defer {
            if let pixels { screen_openexr_free(pixels) }
            if let declaredColorSpace { screen_openexr_free(declaredColorSpace) }
            if let message { screen_openexr_free(message) }
        }
        guard succeeded, let pixels, width > 0, height > 0 else {
            throw NativeMediaError.unreadable(
                message.map { String(cString: $0) } ?? url.lastPathComponent
            )
        }
        let count = Int(width * height) * 4
        let rgba = Array(UnsafeBufferPointer(start: pixels, count: count))
        guard rgba.allSatisfy(\.isFinite) else {
            throw NativeMediaError.unreadable(
                "\(url.lastPathComponent) contiene muestras no finitas"
            )
        }
        return DecodedNativeFrame(
            width: Int(width),
            height: Int(height),
            rgba: rgba,
            sourceDescription: url.lastPathComponent
        )
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

    var authoredPlacementID: String {
        switch self {
        case .vfxComparisonReference: "one-to-one"
        default: "fit"
        }
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
