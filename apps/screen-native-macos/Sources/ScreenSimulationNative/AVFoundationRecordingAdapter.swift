@preconcurrency import AVFoundation
import CoreVideo
import CryptoKit
import Foundation
import VideoToolbox

struct AVFoundationRecordingResult: Sendable {
    let width: Int
    let height: Int
    let rgba8: [UInt8]
    let encodedData: Data
    let encodedSHA256: [UInt8]
}

enum AVFoundationRecordingError: Error {
    case invalidRequest
    case writerFailed
    case readerFailed
}

enum AVFoundationRecordingAdapter {
    static func roundTrip(
        profileID: String,
        width: Int,
        height: Int,
        bitsPerSecond: Int,
        rgba8: [UInt8]
    ) throws -> AVFoundationRecordingResult {
        guard width > 0, height > 0, rgba8.count == width * height * 4 else {
            throw AVFoundationRecordingError.invalidRequest
        }
        let codec: AVVideoCodecType
        let fileType: AVFileType
        var compression: [String: Any] = [:]
        switch profileID {
        case "generic-hevc-main10-video-v1":
            codec = .hevc
            fileType = .mov
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel
            compression[AVVideoAverageBitRateKey] = bitsPerSecond
        case "generic-h264-high-video-v1":
            codec = .h264
            fileType = .mp4
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            compression[AVVideoAverageBitRateKey] = bitsPerSecond
        case "generic-prores-422-hq-v1":
            codec = .proRes422HQ
            fileType = .mov
        default:
            throw AVFoundationRecordingError.invalidRequest
        }

        let directory = FileManager.default.temporaryDirectory
        let url = directory.appendingPathComponent("screen-recording-\(UUID().uuidString)")
            .appendingPathExtension(fileType == .mp4 ? "mp4" : "mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ]
        )
        guard writer.canAdd(input) else { throw AVFoundationRecordingError.writerFailed }
        writer.add(input)
        guard writer.startWriting() else { throw AVFoundationRecordingError.writerFailed }
        writer.startSession(atSourceTime: .zero)
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary,
            &pixelBuffer
        ) == kCVReturnSuccess, let pixelBuffer else {
            throw AVFoundationRecordingError.writerFailed
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
            for y in 0 ..< height {
                let dst = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                let src = y * width * 4
                for x in 0 ..< width {
                    dst[x * 4] = rgba8[src + x * 4 + 2]
                    dst[x * 4 + 1] = rgba8[src + x * 4 + 1]
                    dst[x * 4 + 2] = rgba8[src + x * 4]
                    dst[x * 4 + 3] = 255
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        guard adaptor.append(pixelBuffer, withPresentationTime: .zero) else {
            throw AVFoundationRecordingError.writerFailed
        }
        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        guard writer.status == .completed else { throw AVFoundationRecordingError.writerFailed }

        let data = try Data(contentsOf: url)
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        guard let track = try awaitValue({ try await asset.loadTracks(withMediaType: .video) }).first else {
            throw AVFoundationRecordingError.readerFailed
        }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        guard reader.canAdd(output) else { throw AVFoundationRecordingError.readerFailed }
        reader.add(output)
        guard reader.startReading(), let sample = output.copyNextSampleBuffer(),
              let decoded = CMSampleBufferGetImageBuffer(sample)
        else { throw AVFoundationRecordingError.readerFailed }
        CVPixelBufferLockBaseAddress(decoded, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(decoded, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(decoded) else {
            throw AVFoundationRecordingError.readerFailed
        }
        let decodedWidth = CVPixelBufferGetWidth(decoded)
        let decodedHeight = CVPixelBufferGetHeight(decoded)
        let rowBytes = CVPixelBufferGetBytesPerRow(decoded)
        var result = [UInt8](repeating: 255, count: decodedWidth * decodedHeight * 4)
        for y in 0 ..< decodedHeight {
            let src = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0 ..< decodedWidth {
                let dst = (y * decodedWidth + x) * 4
                result[dst] = src[x * 4 + 2]
                result[dst + 1] = src[x * 4 + 1]
                result[dst + 2] = src[x * 4]
            }
        }
        return AVFoundationRecordingResult(
            width: decodedWidth,
            height: decodedHeight,
            rgba8: result,
            encodedData: data,
            encodedSHA256: Array(SHA256.hash(data: data))
        )
    }

    private static func awaitValue<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let result = LockedResult<T>()
        Task {
            do { result.store(.success(try await operation())) }
            catch { result.store(.failure(error)) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.load().get()
    }
}

private final class LockedResult<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<Value, Error>?
    func store(_ value: Result<Value, Error>) { lock.withLock { self.value = value } }
    func load() -> Result<Value, Error> { lock.withLock { value! } }
}
