import Foundation
import ScreenPhysicalBridge
import StudioColor

struct RecordingOutputExecution: Sendable {
    let frame: StudioColorMetalFrame
    let rgba8: [UInt8]
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
        let rgba8 = encoded.map { UInt8((min(max($0, 0), 1) * 255).rounded()) }
        var preview = encoded
        try inverse(&preview, transformID: transformID, width: cameraRendered.width, height: cameraRendered.height)
        let frame = try display.makeACEScgFrame(
            width: cameraRendered.width,
            height: cameraRendered.height,
            encodedRGBA: preview,
            input: try acescgInput(),
            alpha: .ignore
        )
        return RecordingOutputExecution(frame: frame, rgba8: rgba8)
    }

    static func codec(
        output: RecordingOutputExecution,
        profileID: String,
        character: Double,
        display: StudioColorMetalDisplay
    ) throws -> RecordingCodecExecution {
        if character == 0 {
            return RecordingCodecExecution(
                frame: output.frame,
                decodedRGBA8: output.rgba8,
                encodedData: Data(),
                encodedBytes: 0,
                encodedSHA256Hex: ""
            )
        }
        let decoded: [UInt8]
        let data: Data
        let hash: [UInt8]
        let width: Int
        let height: Int
        let transformID: String
        if profileID == iphoneHeicProfileID || profileID == genericJpegProfileID {
            let quality = min(max(calibratedHeicQuality / max(character, 0.0001), 0), 1)
            let result = try ImageIOHeicRecordingAdapter.roundTrip(.init(
                profileID: profileID,
                width: output.frame.width,
                height: output.frame.height,
                quality: quality,
                colorSpace: profileID == iphoneHeicProfileID ? .displayP3D65 : .rec709,
                rgba8: output.rgba8
            ))
            decoded = result.rgba8
            data = result.encodedData
            hash = result.encodedSHA256
            width = result.width
            height = result.height
            transformID = profileID == iphoneHeicProfileID
                ? iphoneHeicOutputTransformID : "generic-srgb-recording-full-v1"
        } else {
            let result = try AVFoundationRecordingAdapter.roundTrip(
                profileID: profileID,
                width: output.frame.width,
                height: output.frame.height,
                bitsPerSecond: Int(80_000_000 / max(character, 0.25)),
                rgba8: output.rgba8
            )
            decoded = result.rgba8
            data = result.encodedData
            hash = result.encodedSHA256
            width = result.width
            height = result.height
            transformID = "generic-rec709-recording-full-v1"
        }
        var encoded = decoded.map { Float($0) / 255 }
        try inverse(&encoded, transformID: transformID, width: width, height: height)
        let frame = try display.makeACEScgFrame(
            width: width,
            height: height,
            encodedRGBA: encoded,
            input: try acescgInput(),
            alpha: .ignore
        )
        return RecordingCodecExecution(
            frame: frame,
            decodedRGBA8: decoded,
            encodedData: data,
            encodedBytes: data.count,
            encodedSHA256Hex: hash.map { String(format: "%02x", $0) }.joined()
        )
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
}
