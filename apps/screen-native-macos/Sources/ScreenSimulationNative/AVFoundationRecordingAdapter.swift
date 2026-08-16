@preconcurrency import AVFoundation
import CoreVideo
import CryptoKit
import Foundation
import VideoToolbox

struct AVFoundationRecordingFrame: Equatable, Sendable {
    let frameIndex: Int64
    let rgba8: [UInt8]
}

struct AVFoundationRecordingRequest: Equatable, Sendable {
    enum Codec: Sendable { case hevcMain8, h264High8 }
    let codec: Codec
    let width: Int
    let height: Int
    let frameRateNumerator: UInt32
    let frameRateDenominator: UInt32
    let firstFrameIndex: Int64
    let bitsPerSecond: Int
    let fixedGOPFrames: Int
    let maximumBFrames: Int
    let frames: [AVFoundationRecordingFrame]

    func validated() throws -> Self {
        let pixels = width.multipliedReportingOverflow(by: height)
        let components = pixels.partialValue.multipliedReportingOverflow(by: 4)
        guard width > 0, height > 0, frameRateNumerator > 0, frameRateDenominator > 0,
              bitsPerSecond > 0, fixedGOPFrames > 0, maximumBFrames >= 0,
              maximumBFrames < fixedGOPFrames, !pixels.overflow, !components.overflow,
              !frames.isEmpty
        else { throw AVFoundationRecordingError.invalidRequest }
        for (offset, frame) in frames.enumerated() {
            guard frame.frameIndex == firstFrameIndex + Int64(offset),
                  frame.rgba8.count == components.partialValue
            else { throw AVFoundationRecordingError.nonChronologicalSequence }
            for alpha in stride(from: 3, to: frame.rgba8.count, by: 4)
                where frame.rgba8[alpha] != 255
            { throw AVFoundationRecordingError.invalidRequest }
        }
        return self
    }
}

struct AVFoundationRecordingResult: Sendable {
    let width: Int
    let height: Int
    let frames: [AVFoundationRecordingFrame]
    let encodedData: Data
    let encodedSHA256: [UInt8]
}

enum AVFoundationRecordingError: Error, Equatable {
    case invalidRequest, nonChronologicalSequence, writerFailed, readerFailed
    case decodedFrameCountMismatch
}

enum AVFoundationRecordingAdapter {
    static func roundTrip(_ unresolved: AVFoundationRecordingRequest) throws
        -> AVFoundationRecordingResult
    {
        let request = try unresolved.validated()
        let (codec, fileType, profile): (AVVideoCodecType, AVFileType, Any) = switch request.codec {
        case .hevcMain8: (.hevc, .mov, kVTProfileLevel_HEVC_Main_AutoLevel)
        case .h264High8: (.h264, .mp4, AVVideoProfileLevelH264HighAutoLevel)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("screen-recording-\(UUID().uuidString)")
            .appendingPathExtension(fileType == .mp4 ? "mp4" : "mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec, AVVideoWidthKey: request.width, AVVideoHeightKey: request.height,
            AVVideoCompressionPropertiesKey: [
                AVVideoProfileLevelKey: profile,
                AVVideoAverageBitRateKey: request.bitsPerSecond,
                AVVideoMaxKeyFrameIntervalKey: request.fixedGOPFrames,
                AVVideoAllowFrameReorderingKey: request.maximumBFrames > 0,
            ],
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
                kCVPixelBufferWidthKey as String: request.width,
                kCVPixelBufferHeightKey as String: request.height,
            ]
        )
        guard writer.canAdd(input) else { throw AVFoundationRecordingError.writerFailed }
        writer.add(input)
        guard writer.startWriting() else { throw AVFoundationRecordingError.writerFailed }
        writer.startSession(atSourceTime: .zero)
        for (offset, frame) in request.frames.enumerated() {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
            let buffer = try makePixelBuffer(frame.rgba8, request.width, request.height)
            let time = CMTime(
                value: Int64(offset) * Int64(request.frameRateDenominator),
                timescale: Int32(request.frameRateNumerator)
            )
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw AVFoundationRecordingError.writerFailed
            }
        }
        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        guard writer.status == .completed else { throw AVFoundationRecordingError.writerFailed }
        let data = try Data(contentsOf: url)
        let frames = try decode(url, request)
        guard frames.count == request.frames.count else {
            throw AVFoundationRecordingError.decodedFrameCountMismatch
        }
        return AVFoundationRecordingResult(
            width: request.width, height: request.height, frames: frames, encodedData: data,
            encodedSHA256: Array(SHA256.hash(data: data))
        )
    }

    private static func makePixelBuffer(_ rgba: [UInt8], _ width: Int, _ height: Int) throws
        -> CVPixelBuffer
    {
        var result: CVPixelBuffer?
        guard CVPixelBufferCreate(
            nil, width, height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &result
        ) == kCVReturnSuccess, let result else { throw AVFoundationRecordingError.writerFailed }
        CVPixelBufferLockBaseAddress(result, [])
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        guard let base = CVPixelBufferGetBaseAddress(result) else {
            throw AVFoundationRecordingError.writerFailed
        }
        let stride = CVPixelBufferGetBytesPerRow(result)
        for y in 0 ..< height {
            let dst = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            let src = y * width * 4
            for x in 0 ..< width {
                dst[x * 4] = rgba[src + x * 4 + 2]
                dst[x * 4 + 1] = rgba[src + x * 4 + 1]
                dst[x * 4 + 2] = rgba[src + x * 4]
                dst[x * 4 + 3] = 255
            }
        }
        return result
    }

    private static func decode(_ url: URL, _ request: AVFoundationRecordingRequest) throws
        -> [AVFoundationRecordingFrame]
    {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        guard let track = try awaitValue({ try await asset.loadTracks(withMediaType: .video) }).first
        else { throw AVFoundationRecordingError.readerFailed }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        guard reader.canAdd(output) else { throw AVFoundationRecordingError.readerFailed }
        reader.add(output)
        guard reader.startReading() else { throw AVFoundationRecordingError.readerFailed }
        var frames: [AVFoundationRecordingFrame] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else {
                throw AVFoundationRecordingError.readerFailed
            }
            frames.append(.init(
                frameIndex: request.firstFrameIndex + Int64(frames.count),
                rgba8: try rgba8(buffer)
            ))
        }
        guard reader.status == .completed else { throw AVFoundationRecordingError.readerFailed }
        return frames
    }

    private static func rgba8(_ buffer: CVPixelBuffer) throws -> [UInt8] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw AVFoundationRecordingError.readerFailed
        }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var result = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0 ..< height {
            let src = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
            for x in 0 ..< width {
                let dst = (y * width + x) * 4
                result[dst] = src[x * 4 + 2]
                result[dst + 1] = src[x * 4 + 1]
                result[dst + 2] = src[x * 4]
            }
        }
        return result
    }

    private static func awaitValue<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) throws -> T {
        let semaphore = DispatchSemaphore(value: 0), result = LockedResult<T>()
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
