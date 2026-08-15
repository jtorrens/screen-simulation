@preconcurrency import AVFoundation
import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import ScreenPhysicalBridge
import StudioColor
import StudioMedia
import UniformTypeIdentifiers
import VideoToolbox

enum NativeOutputError: Error, LocalizedError {
    case invalidFrame, cannotCreateWriter, cannotAppend(Int), cannotFinish, unsupported(String)
    var errorDescription: String? {
        switch self {
        case .invalidFrame: "Frame de salida no válido."
        case .cannotCreateWriter: "No se puede crear el writer AVFoundation."
        case let .cannotAppend(frame): "No se puede codificar el frame \(frame)."
        case .cannotFinish: "No se puede finalizar el archivo de salida."
        case let .unsupported(value): "Combinación de salida no compatible: \(value)."
        }
    }
}

@MainActor
enum NativeOutputRenderer {
    typealias FrameProvider = (Int) async throws -> StudioColorMetalFrame
    typealias Progress = (Int, Int) -> Void

    static func render(
        configuration: StudioResolvedRenderConfiguration,
        destination: URL,
        audioSource: URL?,
        display: StudioColorMetalDisplay,
        frameProvider: FrameProvider,
        progress: Progress
    ) async throws -> URL {
        let format = configuration.format
        let frameRange = configuration.frameRange
        let frameRate = configuration.frameRate
        let alpha = configuration.alpha.colorAssociation
        let frames = Array(frameRange)
        guard let firstIndex = frames.first else { throw NativeOutputError.invalidFrame }
        try validate(format: format, configuration: configuration)
        let first = try await frameProvider(firstIndex)
        let output = outputTransform(for: configuration)
        if format.isMovie {
            guard let output else {
                throw NativeOutputError.unsupported("los masters scene-linear requieren secuencia OpenEXR")
            }
            let finalURL = destination.deletingPathExtension()
                .appendingPathExtension(format.fileExtension)
            try? FileManager.default.removeItem(at: finalURL)
            let writerURL = configuration.includeAudio && audioSource != nil
                ? finalURL.deletingLastPathComponent()
                    .appendingPathComponent(".\(UUID().uuidString)-video")
                    .appendingPathExtension(format.fileExtension)
                : finalURL
            let writer = try MovieWriter(
                url: writerURL, width: first.width, height: first.height,
                frameRate: frameRate, format: format,
                peakNits: configuration.peakNits,
                signalRange: configuration.signalRange,
                alpha: format.supportsAlpha ? alpha : .ignore, output: output
            )
            for (position, index) in frames.enumerated() {
                try Task.checkCancellation()
                let frame = index == firstIndex ? first : try await frameProvider(index)
                try await writer.append(
                    frame: frame, presentationFrame: position,
                    display: display, output: output
                )
                progress(position + 1, frames.count)
            }
            try await writer.finish()
            if configuration.includeAudio, let audioSource {
                try await muxAudio(
                    videoURL: writerURL, audioURL: audioSource,
                    sourceStart: CMTime(
                        value: CMTimeValue(frameRange.lowerBound)
                            * CMTimeValue(frameRate.denominator),
                        timescale: CMTimeScale(frameRate.numerator)
                    ),
                    duration: CMTime(
                        value: CMTimeValue(frames.count)
                            * CMTimeValue(frameRate.denominator),
                        timescale: CMTimeScale(frameRate.numerator)
                    ),
                    outputURL: finalURL,
                    fileType: format.fileExtension == "mp4" ? .mp4 : .mov
                )
                try? FileManager.default.removeItem(at: writerURL)
            }
            return finalURL
        }
        let directory = destination
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (position, index) in frames.enumerated() {
            try Task.checkCancellation()
            let frame = index == firstIndex ? first : try await frameProvider(index)
            let name = String(format: "ScreenSimulation-%08d", index)
            let url = directory.appendingPathComponent(name).appendingPathExtension(format.fileExtension)
            switch format {
            case .openEXR:
                var values = try display.readLinearRGBA(frame)
                applyOutputAlpha(alpha, to: &values)
                if configuration.target == .aces2065 {
                    let processor = try StudioColorEngine.bundled().cachedColorSpaceProcessor(
                        source: "ACEScg", destination: "ACES2065-1"
                    )
                    try processor.apply(toRGBA: &values)
                }
                try encodeEXR(values, width: frame.width, height: frame.height)
                    .write(to: url, options: .atomic)
            case .dpx10RGB:
                guard let output else { throw NativeOutputError.unsupported("DPX requiere ODT") }
                try encodeDPX(
                    try display.renderRGBAFloat(frame, output: output),
                    width: frame.width, height: frame.height
                ).write(to: url, options: .atomic)
            case .tiff16:
                guard let output else { throw NativeOutputError.unsupported("TIFF requiere ODT") }
                try encodeTIFF16(
                    try display.renderRGBAFloat(frame, output: output),
                    width: frame.width, height: frame.height,
                    colorSpace: output.colorSpace
                ).write(to: url, options: .atomic)
            default:
                throw NativeOutputError.unsupported(format.displayName)
            }
            progress(position + 1, frames.count)
        }
        return directory
    }

    static func renderCurrentFrame(
        frame: StudioColorMetalFrame,
        displayTransform: StudioColorOutputTransform,
        metadata: [String: Any],
        destination: URL,
        display: StudioColorMetalDisplay
    ) throws {
        let rgba8 = try display.renderRGBA8(frame, output: displayTransform)
        let document = try FrameCheckPNG.finalizedMetadata(metadata, rgba8: rgba8)
        try FrameCheckPNG.encode(
            rgba8: rgba8, width: frame.width, height: frame.height,
            colorSpace: displayTransform.colorSpace, metadata: document
        ).write(to: destination, options: .atomic)
    }

    private static func outputTransform(
        for configuration: StudioResolvedRenderConfiguration
    ) -> StudioColorOutputTransform? {
        if configuration.pipeline == .davinciColorManaged,
           configuration.target == .sdr {
            return StudioColorOutputTransform(
                id: "render-dcm-sdr", label: "DCM · SDR",
                colorSpace: "Gamma 2.4 Encoded Rec.709", encoding: .rec709
            )
        }
        guard let display = configuration.display,
              let view = configuration.view else { return nil }
        let encoding: StudioColorOutputTransform.Encoding =
            configuration.target == .hdr ? .rec2100PQ : .rec709
        return StudioColorOutputTransform(
            id: "render-\(configuration.pipeline.rawValue)-\(configuration.target.rawValue)",
            label: "Render efectivo",
            display: display, view: view, encoding: encoding
        )
    }

    private static func validate(
        format: StudioOutputFormat,
        configuration: StudioResolvedRenderConfiguration
    ) throws {
        guard format.supports(target: configuration.target) else {
            throw NativeOutputError.unsupported(
                "\(format.displayName) no admite el destino \(configuration.target.rawValue)"
            )
        }
        guard !configuration.motionBlurEnabled
            || (2...64).contains(configuration.motionSamples) else {
            throw NativeOutputError.unsupported(
                "el desenfoque de movimiento requiere entre 2 y 64 muestras temporales"
            )
        }
        guard format.supportedPixelEncodings.contains(configuration.pixelEncoding) else {
            throw NativeOutputError.unsupported(
                "\(format.displayName) no admite \(configuration.pixelEncoding.label)"
            )
        }
        guard format.supportedSignalRanges(for: configuration.pixelEncoding)
            .contains(configuration.signalRange) else {
            throw NativeOutputError.unsupported(
                "\(configuration.pixelEncoding.label) no admite rango \(configuration.signalRange.label) en el writer vigente"
            )
        }
    }

    private static func applyOutputAlpha(
        _ alpha: StudioColorAlphaAssociation,
        to values: inout [Float]
    ) {
        guard alpha != .premultiplied else { return }
        for offset in stride(from: 0, to: values.count, by: 4) {
            let value = values[offset + 3]
            if value > 0 {
                values[offset] /= value
                values[offset + 1] /= value
                values[offset + 2] /= value
            } else {
                values[offset] = 0
                values[offset + 1] = 0
                values[offset + 2] = 0
            }
            if alpha == .ignore { values[offset + 3] = 1 }
        }
    }

    private static func muxAudio(
        videoURL: URL,
        audioURL: URL,
        sourceStart: CMTime,
        duration: CMTime,
        outputURL: URL,
        fileType: AVFileType
    ) async throws {
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        let composition = AVMutableComposition()
        guard let videoSource = try await videoAsset.loadTracks(withMediaType: .video).first,
              let videoTrack = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
              )
        else { throw NativeOutputError.cannotFinish }
        try videoTrack.insertTimeRange(
            CMTimeRange(start: .zero, duration: duration), of: videoSource, at: .zero
        )
        if let audioSource = try await audioAsset.loadTracks(withMediaType: .audio).first,
           let audioTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try audioTrack.insertTimeRange(
                CMTimeRange(start: sourceStart, duration: duration), of: audioSource, at: .zero
            )
        }
        guard let exporter = AVAssetExportSession(
            asset: composition, presetName: AVAssetExportPresetPassthrough
        ) else { throw NativeOutputError.cannotFinish }
        exporter.outputURL = outputURL
        exporter.outputFileType = fileType
        await withCheckedContinuation { continuation in
            exporter.exportAsynchronously { continuation.resume() }
        }
        guard exporter.status == .completed else { throw NativeOutputError.cannotFinish }
    }

    private static func encodeEXR(_ values: [Float], width: Int, height: Int) throws -> Data {
        var bytes: UnsafeMutablePointer<UInt8>?
        var count = 0
        var message: UnsafeMutablePointer<CChar>?
        let success = values.withUnsafeBufferPointer {
            screen_openexr_encode_rgba_half(
                $0.baseAddress, UInt32(width), UInt32(height), &bytes, &count, &message
            )
        }
        guard success, let bytes else {
            defer { if let message { screen_openexr_free(message) } }
            throw NativeOutputError.unsupported(message.map { String(cString: $0) } ?? "OpenEXR")
        }
        defer { screen_openexr_free(bytes) }
        return Data(bytes: bytes, count: count)
    }

    private static func encodeTIFF16(
        _ values: [Float], width: Int, height: Int, colorSpace: CGColorSpace?
    ) throws -> Data {
        var words = values.map { UInt16((min(1, max(0, $0)) * 65_535).rounded()) }
        guard let provider = words.withUnsafeMutableBytes({ CGDataProvider(data: Data($0) as CFData) }),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64,
                bytesPerRow: width * 8, space: colorSpace ?? CGColorSpace(name: CGColorSpace.itur_709)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                    .union(.byteOrder16Little),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              )
        else { throw NativeOutputError.invalidFrame }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, 1, nil) else {
            throw NativeOutputError.invalidFrame
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw NativeOutputError.invalidFrame }
        return data as Data
    }

    /// SMPTE ST 268 RGB 10-bit, big-endian, filled method A; extracted from CREDITOS-HDR.
    private static func encodeDPX(_ values: [Float], width: Int, height: Int) throws -> Data {
        guard values.count == width * height * 4 else { throw NativeOutputError.invalidFrame }
        var output = Data(count: 2_048)
        putUInt32(0x5344_5058, at: 0, in: &output)
        putUInt32(2_048, at: 4, in: &output)
        putASCII("V2.0", count: 8, at: 8, in: &output)
        putUInt32(UInt32(2_048 + width * height * 4), at: 16, in: &output)
        putUInt32(1, at: 20, in: &output)
        putUInt16(1, at: 770, in: &output)
        putUInt32(UInt32(width), at: 772, in: &output)
        putUInt32(UInt32(height), at: 776, in: &output)
        output[800] = 50
        output[801] = 2
        output[802] = 2
        output[803] = 10
        putUInt16(1, at: 804, in: &output)
        putUInt32(2_048, at: 808, in: &output)
        putASCII("RGB 10-bit full range", count: 32, at: 820, in: &output)
        for pixel in 0 ..< width * height {
            let base = pixel * 4
            let r = UInt32((min(1, max(0, values[base])) * 1_023).rounded())
            let g = UInt32((min(1, max(0, values[base + 1])) * 1_023).rounded())
            let b = UInt32((min(1, max(0, values[base + 2])) * 1_023).rounded())
            var word = ((r & 0x3FF) << 22) | ((g & 0x3FF) << 12) | ((b & 0x3FF) << 2)
            word = word.bigEndian
            withUnsafeBytes(of: &word) { output.append(contentsOf: $0) }
        }
        return output
    }

    private static func putUInt16(_ value: UInt16, at offset: Int, in data: inout Data) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { data.replaceSubrange(offset ..< offset + 2, with: $0) }
    }
    private static func putUInt32(_ value: UInt32, at offset: Int, in data: inout Data) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { data.replaceSubrange(offset ..< offset + 4, with: $0) }
    }
    private static func putASCII(_ value: String, count: Int, at offset: Int, in data: inout Data) {
        let bytes = Array(value.utf8.prefix(count))
        data.replaceSubrange(offset ..< offset + bytes.count, with: bytes)
    }
}

@MainActor
private final class MovieWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let frameRate: StudioFrameRate
    private let format: StudioOutputFormat
    private let alpha: StudioColorAlphaAssociation
    private let signalRange: StudioSignalRange
    private let usesYUV: Bool
    private let usesTenBitYUV: Bool

    init(
        url: URL, width: Int, height: Int, frameRate: StudioFrameRate,
        format: StudioOutputFormat, peakNits: Double,
        signalRange: StudioSignalRange,
        alpha: StudioColorAlphaAssociation,
        output: StudioColorOutputTransform
    ) throws {
        self.frameRate = frameRate
        self.format = format
        self.alpha = alpha
        self.signalRange = signalRange
        usesYUV = format != .proRes4444 && format != .proRes4444XQ
        usesTenBitYUV = switch format {
        case .h265Low, .h265Medium, .h265High: true
        default: false
        }
        writer = try AVAssetWriter(outputURL: url, fileType: format == .h264Low || format == .h264Medium || format == .h264High ? .mp4 : .mov)
        let codec: AVVideoCodecType
        switch format {
        case .proRes4444: codec = .proRes4444
        case .proRes4444XQ: codec = AVVideoCodecType(rawValue: "ap4x")
        case .h264Low, .h264Medium, .h264High: codec = .h264
        case .h265Low, .h265Medium, .h265High: codec = .hevc
        default: throw NativeOutputError.unsupported(format.displayName)
        }
        var compression: [String: Any] = [:]
        if let bpp = format.bitsPerPixelPerFrame {
            compression[AVVideoAverageBitRateKey] = Int(
                Double(width * height) * frameRate.framesPerSecond * bpp
            )
        }
        if format == .proRes4444 || format == .proRes4444XQ {
            compression[kVTCompressionPropertyKey_AlphaChannelMode as String] = alpha == .premultiplied
                ? kVTAlphaChannelMode_PremultipliedAlpha : kVTAlphaChannelMode_StraightAlpha
        }
        var settings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
        ]
        if output.encoding == .rec2100PQ {
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_SMPTE_ST_2084_PQ,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
        } else {
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ]
        }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        input.mediaTimeScale = CMTimeScale(frameRate.numerator)
        let pixelFormat: OSType
        if format == .proRes4444 || format == .proRes4444XQ {
            pixelFormat = kCVPixelFormatType_64RGBAHalf
        } else if usesTenBitYUV {
            pixelFormat = signalRange == .full
                ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        } else {
            pixelFormat = signalRange == .full
                ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        }
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
        )
        guard writer.canAdd(input) else { throw NativeOutputError.cannotCreateWriter }
        writer.add(input)
        guard writer.startWriting() else { throw NativeOutputError.cannotCreateWriter }
        writer.startSession(atSourceTime: .zero)
        _ = peakNits // retained as authored job metadata; OCIO transform remains preset-authoritative.
    }

    func append(
        frame: StudioColorMetalFrame, presentationFrame: Int,
        display: StudioColorMetalDisplay, output: StudioColorOutputTransform
    ) async throws {
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(2))
        }
        guard let pool = adaptor.pixelBufferPool else { throw NativeOutputError.cannotCreateWriter }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess,
              let buffer else { throw NativeOutputError.cannotCreateWriter }
        if usesYUV {
            let matrix: StudioColorSignalMatrix = output.encoding == .rec2100PQ
                ? .bt2020 : .bt709
            try display.renderYUV420(
                frame,
                output: output,
                into: buffer,
                matrix: matrix,
                range: signalRange == .full ? .full : .video,
                tenBit: usesTenBitYUV
            )
        } else {
            try display.render(frame, output: output, into: buffer, alpha: alpha)
        }
        let time = CMTime(
            value: CMTimeValue(presentationFrame) * CMTimeValue(frameRate.denominator),
            timescale: CMTimeScale(frameRate.numerator)
        )
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw NativeOutputError.cannotAppend(presentationFrame)
        }
    }

    func finish() async throws {
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw NativeOutputError.cannotFinish }
    }
}
