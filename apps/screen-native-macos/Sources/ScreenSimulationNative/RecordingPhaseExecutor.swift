import Foundation
import Metal
import ScreenPhysicalBridge
import StudioColor

struct RecordingOutputExecution: Sendable {
    let frame: StudioColorMetalFrame
    let encodedRGBA: [Float]
    let rgba8: [UInt8]
    /// The physical occlusion matte is not a recording-codec channel. It remains an
    /// independent composition artifact while only RGB performs the real encode/decode.
    let physicalMatte: [Float]
}

struct RecordingCodecExecution: Sendable {
    let frame: StudioColorMetalFrame
    let decodedRGBA8: [UInt8]
    let encodedData: Data
    let encodedBytes: Int
    let encodedSHA256Hex: String
}

enum RecordingPhaseExecutionError: Error, LocalizedError {
    case bridge(String)
    case unsupportedProfile(String)
    case missingACEScgInput

    var errorDescription: String? {
        switch self {
        case let .bridge(message): message
        case let .unsupportedProfile(profile): "Perfil de grabación no ejecutable en macOS: \(profile)"
        case .missingACEScgInput: "Falta el Input Transform ACEScg requerido."
        }
    }
}

@MainActor
enum RecordingPhaseExecutor {
    static let iphoneHeicOutputTransformID = "iphone-heic-display-p3-srgb-full-v2"
    static let iphoneHeicProfileID = "iphone-heic-photo-v1"
    static let calibratedHeicQuality = 0.82
    static let genericJpegProfileID = "generic-jpeg-photo-v1"

    static func delivery(
        cameraRendered: StudioColorMetalFrame,
        width: Int,
        height: Int,
        placementID: String,
        backgroundID: String,
        display: StudioColorMetalDisplay
    ) throws -> StudioColorMetalFrame {
        let input = try display.readLinearRGBA(cameraRendered)
        var output = [Float](repeating: 0, count: width * height * 4)
        var bridgeError: UnsafePointer<CChar>?
        let placement: UInt32 = switch placementID {
        case "fit": 0
        case "one-to-one": 1
        case "fill-crop": 2
        default: throw RecordingPhaseExecutionError.bridge(
            "Colocación Delivery Raster desconocida: \(placementID)"
        )
        }
        let background: UInt32 = backgroundID == "transparent" ? 0 : 1
        let succeeded = input.withUnsafeBufferPointer { inputBuffer in
            output.withUnsafeMutableBufferPointer { outputBuffer in
                screen_delivery_raster_rgba32f(
                    inputBuffer.baseAddress,
                    UInt32(cameraRendered.width), UInt32(cameraRendered.height),
                    outputBuffer.baseAddress,
                    UInt32(width), UInt32(height),
                    placement, background, &bridgeError
                )
            }
        }
        guard succeeded else {
            throw RecordingPhaseExecutionError.bridge(
                bridgeError.map(String.init(cString:)) ?? "Delivery Raster ha fallado."
            )
        }
        return try display.makeACEScgFrame(
            width: width,
            height: height,
            encodedRGBA: output,
            input: try acescgInput(),
            alpha: backgroundID == "transparent" ? .premultiplied : .ignore
        )
    }

    static func output(
        cameraRendered: StudioColorMetalFrame,
        transformID: String,
        display: StudioColorMetalDisplay
    ) throws -> RecordingOutputExecution {
        let input = try display.readLinearRGBA(cameraRendered)
        let physicalMatte = stride(from: 3, to: input.count, by: 4).map { input[$0] }
        var encoded = [Float](repeating: 0, count: input.count)
        var bridgeError: UnsafePointer<CChar>?
        let succeeded = transformID.utf8CString.withUnsafeBufferPointer { id in
            let view = ScreenUTF8View(
                bytes: UnsafeRawPointer(id.baseAddress!).assumingMemoryBound(to: UInt8.self),
                count: max(0, id.count - 1)
            )
            return input.withUnsafeBufferPointer { inputBuffer in
                encoded.withUnsafeMutableBufferPointer { outputBuffer in
                    screen_recording_output_transform_rgba32f(
                        view,
                        inputBuffer.baseAddress,
                        outputBuffer.baseAddress,
                        UInt32(cameraRendered.width),
                        UInt32(cameraRendered.height),
                        &bridgeError
                    )
                }
            }
        }
        guard succeeded else {
            throw RecordingPhaseExecutionError.bridge(
                bridgeError.map(String.init(cString:)) ?? "Recording Output ha fallado."
            )
        }
        // Camera recording formats own RGB only. Keep their encoded input explicitly opaque;
        // the physical matte travels beside the codec and is restored after decoding.
        for alpha in stride(from: 3, to: encoded.count, by: 4) { encoded[alpha] = 1 }
        let rgba8 = encoded.map { UInt8((min(max($0, 0), 1) * 255).rounded()) }
        var preview = encoded
        try inverse(&preview, transformID: transformID, width: cameraRendered.width, height: cameraRendered.height)
        try restorePhysicalMatte(physicalMatte, to: &preview)
        let frame = try makeIndependentLinearFrame(
            width: cameraRendered.width,
            height: cameraRendered.height,
            rgba: preview,
            device: cameraRendered.texture.device
        )
        return RecordingOutputExecution(
            frame: frame,
            encodedRGBA: encoded,
            rgba8: rgba8,
            physicalMatte: physicalMatte
        )
    }

    static func codec(
        output: RecordingOutputExecution,
        profileID: String,
        character: Double,
        outputTransformID: String,
        frameRateNumerator: UInt32 = 24,
        frameRateDenominator: UInt32 = 1,
        display: StudioColorMetalDisplay
    ) throws -> RecordingCodecExecution {
        if character == 0 {
            var diagnostic = output.rgba8
            restorePhysicalMatte8(output.physicalMatte, to: &diagnostic)
            return RecordingCodecExecution(
                frame: output.frame,
                decodedRGBA8: diagnostic,
                encodedData: Data(),
                encodedBytes: 0,
                encodedSHA256Hex: ""
            )
        }
        let plan = try prepareExecutionPlan(
            profileID: profileID,
            character: character,
            frameRateNumerator: frameRateNumerator,
            frameRateDenominator: frameRateDenominator,
            firstFrameIndex: 0,
            frameCount: 1
        )
        let decoded: [Float]
        let data: Data
        let hash: [UInt8]
        let width: Int
        let height: Int
        let transformID: String
        switch plan.adapter_kind {
        case 0, 1:
            let result = try ImageIOHeicRecordingAdapter.roundTrip(.init(
                profileID: profileID,
                format: plan.adapter_kind == 0 ? .heic : .jpeg,
                width: output.frame.width,
                height: output.frame.height,
                quality: Double(plan.quality),
                colorSpace: plan.adapter_kind == 0 ? .displayP3D65 : .rec709,
                rgba8: output.rgba8
            ))
            decoded = result.rgba8.map { Float($0) / 255 }
            data = result.encodedData
            hash = result.encodedSHA256
            width = result.width
            height = result.height
            transformID = outputTransformID
        case 2 ... 5:
            let codec: AVFoundationRecordingRequest.Codec = switch plan.adapter_kind {
            case 2: .h264High8
            case 3: .hevcMain10
            case 4: .proRes422HQ
            case 5: .proRes4444
            default: throw RecordingPhaseExecutionError.unsupportedProfile(profileID)
            }
            let color: AVFoundationRecordingRequest.Color = outputTransformID
                == "generic-rec2100-pq-recording-full-v1" ? .rec2100PQ : .rec709
            let result = try AVFoundationRecordingAdapter.roundTrip(.init(
                codec: codec,
                color: color,
                width: output.frame.width,
                height: output.frame.height,
                frameRateNumerator: frameRateNumerator,
                frameRateDenominator: frameRateDenominator,
                firstFrameIndex: 0,
                bitsPerSecond: Int(plan.bits_per_second),
                frames: [.init(frameIndex: 0, rgba: output.encodedRGBA)]
            ))
            guard let frame = result.frames.first else {
                throw RecordingPhaseExecutionError.unsupportedProfile(profileID)
            }
            decoded = frame.rgba
            data = result.encodedData
            hash = result.encodedSHA256
            width = result.width
            height = result.height
            transformID = outputTransformID
        default: throw RecordingPhaseExecutionError.unsupportedProfile(profileID)
        }
        var encoded = decoded
        try inverse(&encoded, transformID: transformID, width: width, height: height)
        try restorePhysicalMatte(output.physicalMatte, to: &encoded)
        let frame = try makeIndependentLinearFrame(
            width: width,
            height: height,
            rgba: encoded,
            device: output.frame.texture.device
        )
        var decodedDiagnostic = decoded.map { UInt8((min(1, max(0, $0)) * 255).rounded()) }
        restorePhysicalMatte8(output.physicalMatte, to: &decodedDiagnostic)
        return RecordingCodecExecution(
            frame: frame,
            decodedRGBA8: decodedDiagnostic,
            encodedData: data,
            encodedBytes: data.count,
            encodedSHA256Hex: hash.map { String(format: "%02x", $0) }.joined()
        )
    }

    private static func prepareExecutionPlan(
        profileID: String,
        character: Double,
        frameRateNumerator: UInt32,
        frameRateDenominator: UInt32,
        firstFrameIndex: Int64,
        frameCount: UInt64
    ) throws -> ScreenRecordingExecutionPlanV2 {
        try profileID.utf8CString.withUnsafeBufferPointer { id in
            let view = ScreenUTF8View(
                bytes: UnsafeRawPointer(id.baseAddress!).assumingMemoryBound(to: UInt8.self),
                count: max(0, id.count - 1)
            )
            var plan = ScreenRecordingExecutionPlanV2()
            var bridgeError: UnsafePointer<CChar>?
            guard screen_recording_prepare_execution_plan(
                view,
                Float(character),
                frameRateNumerator,
                frameRateDenominator,
                firstFrameIndex,
                frameCount,
                &plan,
                &bridgeError
            ) else {
                throw RecordingPhaseExecutionError.bridge(
                    bridgeError.map(String.init(cString:))
                        ?? "Application no pudo resolver Recording."
                )
            }
            return plan
        }
    }

    private static func acescgInput() throws -> StudioColorInputTransform {
        guard let input = StudioColorInputTransform.catalog.first(where: { $0.id == "acescg" })
        else { throw RecordingPhaseExecutionError.missingACEScgInput }
        return input
    }

    private static func inverse(
        _ rgba: inout [Float], transformID: String, width: Int, height: Int
    ) throws {
        var bridgeError: UnsafePointer<CChar>?
        let succeeded = transformID.utf8CString.withUnsafeBufferPointer { id in
            let view = ScreenUTF8View(
                bytes: UnsafeRawPointer(id.baseAddress!).assumingMemoryBound(to: UInt8.self),
                count: max(0, id.count - 1)
            )
            return rgba.withUnsafeMutableBufferPointer { buffer in
                screen_recording_output_inverse_rgba32f(
                    view, buffer.baseAddress, UInt32(width), UInt32(height), &bridgeError
                )
            }
        }
        guard succeeded else {
            throw RecordingPhaseExecutionError.bridge(
                bridgeError.map(String.init(cString:)) ?? "Preview Recording Output ha fallado."
            )
        }
    }

    private static func restorePhysicalMatte(
        _ matte: [Float], to rgba: inout [Float]
    ) throws {
        guard rgba.count == matte.count * 4 else {
            throw RecordingPhaseExecutionError.bridge(
                "El matte físico no coincide con el raster Recording."
            )
        }
        for (pixel, alpha) in matte.enumerated() { rgba[pixel * 4 + 3] = alpha }
    }

    private static func restorePhysicalMatte8(
        _ matte: [Float], to rgba: inout [UInt8]
    ) {
        guard rgba.count == matte.count * 4 else { return }
        for (pixel, alpha) in matte.enumerated() {
            rgba[pixel * 4 + 3] = UInt8((min(1, max(0, alpha)) * 255).rounded())
        }
    }

    /// Uploads an already-linear ACEScg artifact without applying alpha association.
    /// RGB may legitimately remain non-zero where the independent physical matte is zero.
    private static func makeIndependentLinearFrame(
        width: Int,
        height: Int,
        rgba: [Float],
        device: MTLDevice
    ) throws -> StudioColorMetalFrame {
        guard width > 0, height > 0, rgba.count == width * height * 4 else {
            throw RecordingPhaseExecutionError.bridge("El raster Recording ACEScg no es válido.")
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw RecordingPhaseExecutionError.bridge(
                "No se pudo publicar el raster Recording ACEScg."
            )
        }
        rgba.withUnsafeBytes { bytes in
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: bytes.baseAddress!,
                bytesPerRow: width * 4 * MemoryLayout<Float>.size
            )
        }
        return StudioColorMetalFrame(texture: texture)
    }
}
