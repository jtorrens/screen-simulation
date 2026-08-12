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
        guard profileID == iphoneHeicProfileID else {
            throw RecordingPhaseExecutionError.unsupportedProfile(profileID)
        }
        let quality = min(max(calibratedHeicQuality / max(character, 0.0001), 0), 1)
        if character == 0 {
            return RecordingCodecExecution(
                frame: output.frame,
                decodedRGBA8: output.rgba8,
                encodedData: Data(),
                encodedBytes: 0,
                encodedSHA256Hex: ""
            )
        }
        let result = try ImageIOHeicRecordingAdapter.roundTrip(.init(
            profileID: profileID,
            width: output.frame.width,
            height: output.frame.height,
            quality: quality,
            colorSpace: .displayP3D65,
            rgba8: output.rgba8
        ))
        var encoded = result.rgba8.map { Float($0) / 255 }
        try inverse(&encoded, transformID: iphoneHeicOutputTransformID, width: result.width, height: result.height)
        let frame = try display.makeACEScgFrame(
            width: result.width,
            height: result.height,
            encodedRGBA: encoded,
            input: try acescgInput(),
            alpha: .ignore
        )
        return RecordingCodecExecution(
            frame: frame,
            decodedRGBA8: result.rgba8,
            encodedData: result.encodedData,
            encodedBytes: result.encodedBytes,
            encodedSHA256Hex: result.encodedSHA256.map { String(format: "%02x", $0) }.joined()
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
