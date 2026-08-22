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
        let plan = try RenderOutputPlan.prepare(
            configuration: configuration,
            selectedDestination: destination
        )
        return try await render(
            configuration: configuration, outputPlan: plan,
            audioSource: audioSource, display: display,
            frameProvider: frameProvider, progress: progress
        )
    }

    static func render(
        configuration: StudioResolvedRenderConfiguration,
        outputPlan: RenderOutputPlan,
        audioSource: URL?,
        display: StudioColorMetalDisplay,
        frameProvider: FrameProvider,
        progress: Progress
    ) async throws -> URL {
        let format = configuration.format
        guard configuration.outputType == .standard else {
            throw NativeOutputError.unsupported("Fusion Scene Package requiere su escritor físico dedicado")
        }
        try configuration.validate()
        try outputPlan.prepareDirectories()
        let frameRange = configuration.frameRange
        let frameRate = configuration.frameRate
        let alpha = configuration.alpha.colorAssociation
        let frames = Array(frameRange)
        guard let firstIndex = frames.first else { throw NativeOutputError.invalidFrame }
        try validate(format: format, configuration: configuration)
        if configuration.composition == .deviceAndSpillSeparate {
            return try await renderDeviceSpillDelivery(
                configuration: configuration, outputPlan: outputPlan,
                display: display, frameProvider: frameProvider, progress: progress
            )
        }
        let first = try await frameProvider(firstIndex)
        let output = try outputTransform(for: configuration)
        if format.isMovie {
            guard let output else {
                throw NativeOutputError.unsupported("los masters scene-linear requieren secuencia OpenEXR")
            }
            let finalURL = outputPlan.destination
            try outputPlan.authorizeWrite(
                to: finalURL, policy: configuration.overwritePolicy
            )
            if FileManager.default.fileExists(atPath: finalURL.path) {
                try FileManager.default.removeItem(at: finalURL)
            }
            let writerURL = configuration.includeAudio && audioSource != nil
                ? finalURL.deletingLastPathComponent()
                    .appendingPathComponent(".\(UUID().uuidString)-video")
                    .appendingPathExtension(format.fileExtension)
                : finalURL
            let firstWIP = configuration.wipReview == nil ? nil : try await wipProcessedRGBA(
                try display.renderRGBAFloat(first, output: output, alpha: .ignore),
                sourceWidth: first.width, sourceHeight: first.height,
                frameNumber: firstIndex, outputFilename: finalURL.lastPathComponent,
                configuration: configuration
            )
            let writer = try MovieWriter(
                url: writerURL, width: firstWIP?.width ?? first.width,
                height: firstWIP?.height ?? first.height,
                frameRate: frameRate, format: format,
                peakNits: configuration.peakNits,
                signalRange: configuration.signalRange,
                alpha: format.supportsAlpha ? alpha : .ignore, output: output
            )
            for (position, index) in frames.enumerated() {
                try Task.checkCancellation()
                let frame = index == firstIndex ? first : try await frameProvider(index)
                if configuration.wipReview != nil {
                    let processed = index == firstIndex ? firstWIP! : try await wipProcessedRGBA(
                        try display.renderRGBAFloat(frame, output: output, alpha: .ignore),
                        sourceWidth: frame.width, sourceHeight: frame.height,
                        frameNumber: index, outputFilename: finalURL.lastPathComponent,
                        configuration: configuration
                    )
                    try await writer.appendEncodedRGBA(
                        processed.rgba, presentationFrame: position
                    )
                } else {
                    try await writer.append(
                        frame: frame, presentationFrame: position,
                        display: display, output: output
                    )
                }
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
        let directory = outputPlan.destination
        for (position, index) in frames.enumerated() {
            try Task.checkCancellation()
            let frame = index == firstIndex ? first : try await frameProvider(index)
            let name = String(format: "%@-%08d", configuration.jobName, index)
            let url = directory.appendingPathComponent(name).appendingPathExtension(format.fileExtension)
            try outputPlan.authorizeWrite(
                to: url, policy: configuration.overwritePolicy
            )
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
                let encoded = try await wipProcessedRGBA(
                    try display.renderRGBAFloat(
                        frame, output: output,
                        alpha: .ignore
                    ),
                    sourceWidth: frame.width, sourceHeight: frame.height,
                    frameNumber: index, outputFilename: url.lastPathComponent,
                    configuration: configuration
                )
                try encodeDPX(
                    encoded.rgba, width: encoded.width, height: encoded.height
                ).write(to: url, options: .atomic)
            case .tiff16:
                guard let output else { throw NativeOutputError.unsupported("TIFF requiere ODT") }
                let encoded = try await wipProcessedRGBA(
                    try display.renderRGBAFloat(
                        frame, output: output,
                        alpha: configuration.wipReview == nil ? alpha : .ignore
                    ),
                    sourceWidth: frame.width, sourceHeight: frame.height,
                    frameNumber: index, outputFilename: url.lastPathComponent,
                    configuration: configuration
                )
                try encodeTIFF16(
                    encoded.rgba, width: encoded.width, height: encoded.height,
                    colorSpace: output.colorSpace, alpha: alpha
                ).write(to: url, options: .atomic)
            default:
                throw NativeOutputError.unsupported(format.displayName)
            }
            progress(position + 1, frames.count)
        }
        return directory
    }

    private static func wipProcessedRGBA(
        _ encodedRGBA: [Float],
        sourceWidth: Int,
        sourceHeight: Int,
        frameNumber: Int,
        outputFilename: String,
        configuration: StudioResolvedRenderConfiguration
    ) async throws -> (rgba: [Float], width: Int, height: Int) {
        guard let preset = configuration.wipReview else {
            return (encodedRGBA, sourceWidth, sourceHeight)
        }
        let opaqueRGBA = try opaqueWIPRGBA(encodedRGBA)
        let result = try await WIPReviewOFXAdapter().render(
            encodedRGBA: opaqueRGBA,
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            frame: frameNumber,
            frameRate: configuration.frameRate.framesPerSecond,
            outputFilename: outputFilename,
            preset: preset
        )
        return (result.rgba, result.raster.width, result.raster.height)
    }

    static func opaqueWIPRGBA(_ rgba: [Float]) throws -> [Float] {
        guard rgba.count.isMultiple(of: 4), rgba.allSatisfy(\.isFinite) else {
            throw NativeOutputError.invalidFrame
        }
        var result = rgba
        for offset in stride(from: 0, to: result.count, by: 4) {
            result[offset + 3] = 1
        }
        return result
    }

    private static func associateStraightRGBA(
        _ rgba: inout [Float],
        as association: StudioColorAlphaAssociation
    ) {
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            let alpha = min(1, max(0, rgba[offset + 3]))
            if association == .premultiplied {
                rgba[offset] *= alpha
                rgba[offset + 1] *= alpha
                rgba[offset + 2] *= alpha
            }
            rgba[offset + 3] = association == .ignore ? 1 : alpha
        }
    }


    private static func renderDeviceSpillDelivery(
        configuration: StudioResolvedRenderConfiguration,
        outputPlan: RenderOutputPlan,
        display: StudioColorMetalDisplay,
        frameProvider: FrameProvider,
        progress: Progress
    ) async throws -> URL {
        guard outputPlan.kind == .deviceSpillDelivery else {
            throw NativeOutputError.invalidFrame
        }
        try outputPlan.prepareDirectories()
        let frames = Array(configuration.frameRange)
        guard !frames.isEmpty else { throw NativeOutputError.invalidFrame }
        let output = try outputTransform(for: configuration)
        var deviceMovie: MovieWriter?
        var spillMovie: MovieWriter?
        for (position, index) in frames.enumerated() {
            try Task.checkCancellation()
            let frame = try await frameProvider(index)
            let source = try display.readLinearRGBA(frame)
            let passes = try editorialDeviceSpillPasses(source)
            let deviceURL = outputPlan.destination.appendingPathComponent(
                configuration.format.isMovie
                    ? "\(configuration.jobName)_Device.\(configuration.format.fileExtension)"
                    : String(format: "%@_Device.%08d.%@", configuration.jobName, index, configuration.format.fileExtension)
            )
            let spillURL = outputPlan.destination.appendingPathComponent(
                configuration.format.isMovie
                    ? "\(configuration.jobName)_Spill.\(configuration.format.fileExtension)"
                    : String(format: "%@_Spill.%08d.%@", configuration.jobName, index, configuration.format.fileExtension)
            )
            try outputPlan.authorizeWrite(to: deviceURL, policy: configuration.overwritePolicy)
            try outputPlan.authorizeWrite(to: spillURL, policy: configuration.overwritePolicy)
            if configuration.format.isMovie {
                guard let output else {
                    throw NativeOutputError.unsupported("las películas requieren encoding de entrega")
                }
                let deviceFrame = try makeACEScgFrame(
                    passes.device, width: frame.width, height: frame.height, display: display
                )
                let spillFrame = try makeACEScgFrame(
                    passes.spill, width: frame.width, height: frame.height, display: display
                )
                if deviceMovie == nil {
                    for url in [deviceURL, spillURL] where FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                    deviceMovie = try MovieWriter(
                        url: deviceURL, width: frame.width, height: frame.height,
                        frameRate: configuration.frameRate, format: configuration.format,
                        peakNits: configuration.peakNits, signalRange: configuration.signalRange,
                        alpha: .straight, output: output
                    )
                    spillMovie = try MovieWriter(
                        url: spillURL, width: frame.width, height: frame.height,
                        frameRate: configuration.frameRate, format: configuration.format,
                        peakNits: configuration.peakNits, signalRange: configuration.signalRange,
                        alpha: .ignore, output: output
                    )
                }
                try await deviceMovie!.append(
                    frame: deviceFrame, presentationFrame: position,
                    display: display, output: output
                )
                try await spillMovie!.append(
                    frame: spillFrame, presentationFrame: position,
                    display: display, output: output
                )
            } else {
                try writeDeviceSpillStill(
                    passes.device, to: deviceURL, width: frame.width, height: frame.height,
                    configuration: configuration, display: display, output: output,
                    alpha: .straight
                )
                try writeDeviceSpillStill(
                    passes.spill, to: spillURL, width: frame.width, height: frame.height,
                    configuration: configuration, display: display, output: output,
                    alpha: .ignore
                )
            }
            progress(position + 1, frames.count)
        }
        try await deviceMovie?.finish()
        try await spillMovie?.finish()
        return outputPlan.destination
    }

    static func editorialDeviceSpillPasses(
        _ rgba: [Float]
    ) throws -> (device: [Float], spill: [Float]) {
        guard rgba.count.isMultiple(of: 4), rgba.allSatisfy({ $0.isFinite }) else {
            throw NativeOutputError.invalidFrame
        }
        var device = rgba
        var spill = [Float](repeating: 0, count: rgba.count)
        for offset in stride(from: 0, to: rgba.count, by: 4) {
            let matte = min(1, max(0, rgba[offset + 3]))
            if matte == 0 {
                device[offset] = 0
                device[offset + 1] = 0
                device[offset + 2] = 0
            }
            device[offset + 3] = matte
            spill[offset] = rgba[offset] * (1 - matte)
            spill[offset + 1] = rgba[offset + 1] * (1 - matte)
            spill[offset + 2] = rgba[offset + 2] * (1 - matte)
            spill[offset + 3] = 1
        }
        return (device, spill)
    }

    private static func makeACEScgFrame(
        _ rgba: [Float], width: Int, height: Int,
        display: StudioColorMetalDisplay
    ) throws -> StudioColorMetalFrame {
        guard let identity = StudioColorInputTransform.catalog.first(where: { $0.id == "acescg" }) else {
            throw NativeOutputError.unsupported("falta el Input Transform ACEScg")
        }
        return try display.makeACEScgFrame(
            width: width, height: height, encodedRGBA: rgba,
            input: identity, alpha: .ignore
        )
    }

    private static func writeDeviceSpillStill(
        _ rgba: [Float], to url: URL, width: Int, height: Int,
        configuration: StudioResolvedRenderConfiguration,
        display: StudioColorMetalDisplay,
        output: StudioColorOutputTransform?,
        alpha: StudioColorAlphaAssociation
    ) throws {
        switch configuration.format {
        case .openEXR:
            var values = rgba
            if configuration.target == .aces2065 {
                let processor = try StudioColorEngine.bundled().cachedColorSpaceProcessor(
                    source: "ACEScg", destination: "ACES2065-1"
                )
                try processor.apply(toRGBA: &values)
            }
            try encodeEXR(values, width: width, height: height).write(to: url, options: .atomic)
        case .dpx10RGB, .tiff16:
            guard let output else { throw NativeOutputError.unsupported("el still requiere ODT") }
            let frame = try makeACEScgFrame(rgba, width: width, height: height, display: display)
            let rendered = try display.renderRGBAFloat(frame, output: output)
            if configuration.format == .dpx10RGB {
                try encodeDPX(rendered, width: width, height: height).write(to: url, options: .atomic)
            } else {
                try encodeTIFF16(
                    rendered, width: width, height: height,
                    colorSpace: output.colorSpace, alpha: alpha
                ).write(to: url, options: .atomic)
            }
        default:
            throw NativeOutputError.unsupported(configuration.format.displayName)
        }
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

    static func outputTransform(
        for configuration: StudioResolvedRenderConfiguration
    ) throws -> StudioColorOutputTransform? {
        if let wipReview = configuration.wipReview {
            return switch wipReview.outputColorSpace {
            case .rec709Gamma24:
                StudioColorOutputTransform(
                    id: "wip-rec709-gamma24", label: "WIP Review · Rec.709 Gamma 2.4",
                    display: "Rec.1886 Rec.709 - Display",
                    view: "ACES 2.0 - SDR 100 nits (Rec.709)", encoding: .rec709
                )
            case .rec2100PQ:
                StudioColorOutputTransform(
                    id: "wip-rec2100-pq", label: "WIP Review · Rec.2100 PQ",
                    display: "Rec.2100-PQ - Display",
                    view: "ACES 2.0 - HDR 1000 nits (Rec.2020)", encoding: .rec2100PQ
                )
            case .rec2100HLG:
                StudioColorOutputTransform(
                    id: "wip-rec2100-hlg", label: "WIP Review · Rec.2100 HLG",
                    display: "Rec.2100-HLG - Display",
                    view: "ACES 2.0 - HDR 1000 nits (P3 D65)", encoding: .rec2100HLG
                )
            }
        }
        if configuration.target == .vfxLog {
            guard let id = configuration.vfxInterchangeEncodingID,
                  let encoding = StudioVFXInterchangeEncoding.catalog.first(where: {
                      $0.id == id
                  })
            else {
                throw NativeOutputError.unsupported(
                    "el intercambio ProRes VFX exige un Log/Gamut explícito"
                )
            }
            return encoding.outputTransform
        }
        if configuration.target == .acescg {
            return .technicalACEScgRaw
        }
        if configuration.target == .aces2065 {
            return .technicalACES2065Raw
        }
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

    static func validate(
        format: StudioOutputFormat,
        configuration: StudioResolvedRenderConfiguration
    ) throws {
        guard format.supports(target: configuration.target) else {
            throw NativeOutputError.unsupported(
                "\(format.displayName) no admite el destino \(configuration.target.rawValue)"
            )
        }
        if configuration.target == .vfxLog {
            guard format == .proRes4444 || format == .proRes4444XQ else {
                throw NativeOutputError.unsupported(
                    "el intercambio VFX vigente admite ProRes 4444 o ProRes 4444 XQ"
                )
            }
            guard let id = configuration.vfxInterchangeEncodingID,
                  StudioVFXInterchangeEncoding.catalog.contains(where: { $0.id == id })
            else {
                throw NativeOutputError.unsupported(
                    "el intercambio ProRes VFX exige un Log/Gamut conocido"
                )
            }
        } else if configuration.vfxInterchangeEncodingID != nil {
            throw NativeOutputError.unsupported(
                "un render que no es VFX Log no puede declarar un Log/Gamut VFX"
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

    static func encodeEXR(_ values: [Float], width: Int, height: Int) throws -> Data {
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

    static func encodeTIFF16(
        _ values: [Float], width: Int, height: Int, colorSpace: CGColorSpace?,
        alpha: StudioColorAlphaAssociation = .premultiplied
    ) throws -> Data {
        var words = values.map { UInt16((min(1, max(0, $0)) * 65_535).rounded()) }
        let alphaInfo: CGImageAlphaInfo = switch alpha {
        case .straight: .last
        case .premultiplied: .premultipliedLast
        case .ignore: .noneSkipLast
        }
        guard let provider = words.withUnsafeMutableBytes({ CGDataProvider(data: Data($0) as CFData) }),
              let image = CGImage(
                width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64,
                bytesPerRow: width * 8, space: colorSpace ?? CGColorSpace(name: CGColorSpace.itur_709)!,
                bitmapInfo: CGBitmapInfo(rawValue: alphaInfo.rawValue)
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
    static func encodeDPX(_ values: [Float], width: Int, height: Int) throws -> Data {
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
final class MovieWriter {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let frameRate: StudioFrameRate
    private let format: StudioOutputFormat
    private let alpha: StudioColorAlphaAssociation
    private let signalRange: StudioSignalRange
    private let usesYUV: Bool
    private let usesTenBitYUV: Bool
    private let width: Int
    private let height: Int
    private let outputEncoding: StudioColorOutputTransform.Encoding

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
        self.width = width
        self.height = height
        outputEncoding = output.encoding
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
        } else if output.encoding == .rec2100HLG {
            settings[AVVideoColorPropertiesKey] = [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
            ]
        } else if output.encoding != .cameraLog,
                  output.encoding != .acescgRaw,
                  output.encoding != .aces2065Raw {
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
                || output.encoding == .rec2100HLG
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

    /// Appends pixels that are already in the writer's exact output encoding.
    /// This is the WIP Review boundary: no inverse ODT or second ODT is applied.
    func appendEncodedRGBA(
        _ rgba: [Float],
        presentationFrame: Int
    ) async throws {
        guard rgba.count == width * height * 4,
              rgba.allSatisfy(\.isFinite) else { throw NativeOutputError.invalidFrame }
        while !input.isReadyForMoreMediaData {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(2))
        }
        guard let pool = adaptor.pixelBufferPool else { throw NativeOutputError.cannotCreateWriter }
        var optionalBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer) == kCVReturnSuccess,
              let buffer = optionalBuffer else { throw NativeOutputError.cannotCreateWriter }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        if usesYUV {
            try writeEncodedYUV420(rgba, into: buffer)
        } else {
            guard let base = CVPixelBufferGetBaseAddress(buffer) else {
                throw NativeOutputError.cannotCreateWriter
            }
            let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0 ..< height {
                let row = base.advanced(by: y * rowBytes)
                    .assumingMemoryBound(to: UInt16.self)
                for x in 0 ..< width {
                    let source = (y * width + x) * 4
                    let destination = x * 4
                    let a = min(1, max(0, rgba[source + 3]))
                    let association = alpha == .premultiplied ? a : 1
                    row[destination] = Float16(rgba[source] * association).bitPattern
                    row[destination + 1] = Float16(rgba[source + 1] * association).bitPattern
                    row[destination + 2] = Float16(rgba[source + 2] * association).bitPattern
                    row[destination + 3] = Float16(alpha == .ignore ? 1 : a).bitPattern
                }
            }
        }
        let time = CMTime(
            value: CMTimeValue(presentationFrame) * CMTimeValue(frameRate.denominator),
            timescale: CMTimeScale(frameRate.numerator)
        )
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw NativeOutputError.cannotAppend(presentationFrame)
        }
    }

    private func writeEncodedYUV420(
        _ rgba: [Float],
        into buffer: CVPixelBuffer
    ) throws {
        guard CVPixelBufferGetPlaneCount(buffer) == 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else {
            throw NativeOutputError.cannotCreateWriter
        }
        let kr: Float = outputEncoding == .rec2100PQ || outputEncoding == .rec2100HLG
            ? 0.2627 : 0.2126
        let kb: Float = outputEncoding == .rec2100PQ || outputEncoding == .rec2100HLG
            ? 0.0593 : 0.0722
        let kg = 1 - kr - kb
        let maximum: Float = usesTenBitYUV ? 1_023 : 255
        let yOffset: Float = signalRange == .video ? (usesTenBitYUV ? 64 : 16) : 0
        let yScale: Float = signalRange == .video ? (usesTenBitYUV ? 876 : 219) : maximum
        let cOffset: Float = usesTenBitYUV ? 512 : 128
        let cScale: Float = signalRange == .video ? (usesTenBitYUV ? 896 : 224) : maximum
        let yRowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for y in 0 ..< height {
            for x in 0 ..< width {
                let offset = (y * width + x) * 4
                let r = min(1, max(0, rgba[offset]))
                let g = min(1, max(0, rgba[offset + 1]))
                let b = min(1, max(0, rgba[offset + 2]))
                let luma = kr * r + kg * g + kb * b
                let code = min(maximum, max(0, yOffset + yScale * luma))
                if usesTenBitYUV {
                    yBase.advanced(by: y * yRowBytes)
                        .assumingMemoryBound(to: UInt16.self)[x] = UInt16(
                            (code * 65_535 / 1_023).rounded()
                        )
                } else {
                    yBase.advanced(by: y * yRowBytes)
                        .assumingMemoryBound(to: UInt8.self)[x] = UInt8(code.rounded())
                }
            }
        }
        let chromaWidth = CVPixelBufferGetWidthOfPlane(buffer, 1)
        let chromaHeight = CVPixelBufferGetHeightOfPlane(buffer, 1)
        let uvRowBytes = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for cy in 0 ..< chromaHeight {
            for cx in 0 ..< chromaWidth {
                var cb: Float = 0
                var cr: Float = 0
                var samples: Float = 0
                for dy in 0 ..< 2 {
                    for dx in 0 ..< 2 {
                        let x = min(width - 1, cx * 2 + dx)
                        let y = min(height - 1, cy * 2 + dy)
                        let offset = (y * width + x) * 4
                        let r = min(1, max(0, rgba[offset]))
                        let g = min(1, max(0, rgba[offset + 1]))
                        let b = min(1, max(0, rgba[offset + 2]))
                        let luma = kr * r + kg * g + kb * b
                        cb += (b - luma) / (2 * (1 - kb))
                        cr += (r - luma) / (2 * (1 - kr))
                        samples += 1
                    }
                }
                let cbCode = min(maximum, max(0, cOffset + cScale * cb / samples))
                let crCode = min(maximum, max(0, cOffset + cScale * cr / samples))
                if usesTenBitYUV {
                    let row = uvBase.advanced(by: cy * uvRowBytes)
                        .assumingMemoryBound(to: UInt16.self)
                    row[cx * 2] = UInt16((cbCode * 65_535 / 1_023).rounded())
                    row[cx * 2 + 1] = UInt16((crCode * 65_535 / 1_023).rounded())
                } else {
                    let row = uvBase.advanced(by: cy * uvRowBytes)
                        .assumingMemoryBound(to: UInt8.self)
                    row[cx * 2] = UInt8(cbCode.rounded())
                    row[cx * 2 + 1] = UInt8(crCode.rounded())
                }
            }
        }
    }

    func finish() async throws {
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw NativeOutputError.cannotFinish }
    }
}
