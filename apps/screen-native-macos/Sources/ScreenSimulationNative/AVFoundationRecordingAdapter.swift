@preconcurrency import AVFoundation
import CoreVideo
import CryptoKit
import Foundation
import VideoToolbox

struct AVFoundationRecordingFrame: Equatable, Sendable {
    let frameIndex: Int64
    let rgba: [Float]
}

struct AVFoundationRecordingRequest: Equatable, Sendable {
    enum Codec: Sendable { case h264High8, hevcMain10, proRes422HQ, proRes4444 }
    enum Color: Sendable { case rec709, rec2100PQ }
    let codec: Codec
    let color: Color
    let width: Int
    let height: Int
    let frameRateNumerator: UInt32
    let frameRateDenominator: UInt32
    let firstFrameIndex: Int64
    let bitsPerSecond: Int
    let frames: [AVFoundationRecordingFrame]

    func validated() throws -> Self {
        let pixels = width.multipliedReportingOverflow(by: height)
        let components = pixels.partialValue.multipliedReportingOverflow(by: 4)
        guard width > 0, height > 0, frameRateNumerator > 0, frameRateDenominator > 0,
              bitsPerSecond >= 0, !pixels.overflow, !components.overflow, !frames.isEmpty,
              (codec == .proRes4444 || (width.isMultiple(of: 2) && height.isMultiple(of: 2)))
        else { throw AVFoundationRecordingError.invalidRequest }
        for (offset, frame) in frames.enumerated() {
            guard frame.frameIndex == firstFrameIndex + Int64(offset),
                  frame.rgba.count == components.partialValue,
                  frame.rgba.allSatisfy({ $0.isFinite && (0 ... 1).contains($0) })
            else { throw AVFoundationRecordingError.nonChronologicalSequence }
            for alpha in stride(from: 3, to: frame.rgba.count, by: 4) where frame.rgba[alpha] != 1 {
                throw AVFoundationRecordingError.invalidRequest
            }
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
    static func roundTrip(_ unresolved: AVFoundationRecordingRequest) throws -> AVFoundationRecordingResult {
        let request = try unresolved.validated()
        let (codec, fileType, profile): (AVVideoCodecType, AVFileType, Any?) = switch request.codec {
        case .h264High8: (.h264, .mp4, AVVideoProfileLevelH264HighAutoLevel)
        case .hevcMain10: (.hevc, .mov, kVTProfileLevel_HEVC_Main10_AutoLevel)
        case .proRes422HQ: (AVVideoCodecType(rawValue: "apch"), .mov, nil)
        case .proRes4444: (.proRes4444, .mov, nil)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("screen-recording-\(UUID().uuidString)")
            .appendingPathExtension(fileType == .mp4 ? "mp4" : "mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        var compression: [String: Any] = [:]
        if request.codec == .h264High8 || request.codec == .hevcMain10 {
            compression[AVVideoMaxKeyFrameIntervalKey] = 1
            compression[AVVideoAllowFrameReorderingKey] = false
            if request.bitsPerSecond > 0 {
                compression[AVVideoAverageBitRateKey] = request.bitsPerSecond
            }
            if let profile { compression[AVVideoProfileLevelKey] = profile }
        }
        let colorProperties: [String: Any] = switch request.color {
        case .rec709: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ]
        case .rec2100PQ: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
            AVVideoTransferFunctionKey: AVVideoTransferFunction_SMPTE_ST_2084_PQ,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
        ]
        }
        var outputSettings: [String: Any] = [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: request.width,
            AVVideoHeightKey: request.height,
            AVVideoColorPropertiesKey: colorProperties,
        ]
        if !compression.isEmpty {
            outputSettings[AVVideoCompressionPropertiesKey] = compression
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = false
        let format = pixelFormat(for: request.codec)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferWidthKey as String: request.width,
                kCVPixelBufferHeightKey as String: request.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
        )
        guard writer.canAdd(input) else { throw AVFoundationRecordingError.writerFailed }
        writer.add(input)
        guard writer.startWriting() else { throw AVFoundationRecordingError.writerFailed }
        writer.startSession(atSourceTime: .zero)
        for (offset, frame) in request.frames.enumerated() {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
            let buffer = try makePixelBuffer(frame.rgba, request)
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

    private static func pixelFormat(for codec: AVFoundationRecordingRequest.Codec) -> OSType {
        switch codec {
        case .h264High8: kCVPixelFormatType_32BGRA
        case .hevcMain10: kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        case .proRes422HQ: kCVPixelFormatType_422YpCbCr10
        case .proRes4444: kCVPixelFormatType_64RGBAHalf
        }
    }

    private static func makePixelBuffer(
        _ rgba: [Float], _ request: AVFoundationRecordingRequest
    ) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        guard CVPixelBufferCreate(
            nil, request.width, request.height, pixelFormat(for: request.codec),
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &result
        ) == kCVReturnSuccess, let result else { throw AVFoundationRecordingError.writerFailed }
        CVPixelBufferLockBaseAddress(result, [])
        defer { CVPixelBufferUnlockBaseAddress(result, []) }
        switch request.codec {
        case .h264High8: try writeBGRA8(rgba, into: result)
        case .hevcMain10: try writeP010(rgba, color: request.color, into: result)
        case .proRes422HQ: try writeV210(rgba, color: request.color, into: result)
        case .proRes4444: try writeRGBAHalf(rgba, into: result)
        }
        return result
    }

    private static func writeBGRA8(_ rgba: [Float], into buffer: CVPixelBuffer) throws {
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw AVFoundationRecordingError.writerFailed }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        for y in 0 ..< height {
            let dst = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in 0 ..< width {
                let src = (y * width + x) * 4
                dst[x * 4] = q8(rgba[src + 2]); dst[x * 4 + 1] = q8(rgba[src + 1])
                dst[x * 4 + 2] = q8(rgba[src]); dst[x * 4 + 3] = 255
            }
        }
    }

    private static func writeP010(
        _ rgba: [Float], color: AVFoundationRecordingRequest.Color, into buffer: CVPixelBuffer
    ) throws {
        guard CVPixelBufferGetPlaneCount(buffer) == 2,
              let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
        else { throw AVFoundationRecordingError.writerFailed }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / 2
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) / 2
        let yWords = yBase.assumingMemoryBound(to: UInt16.self)
        let uvWords = uvBase.assumingMemoryBound(to: UInt16.self)
        for y in 0 ..< height { for x in 0 ..< width {
            yWords[y * yStride + x] = q10(rgbToYuv(rgb(rgba, width, x, y), color).0) << 6
        }}
        for y in stride(from: 0, to: height, by: 2) { for x in stride(from: 0, to: width, by: 2) {
            var cb: Float = 0, cr: Float = 0
            for dy in 0 ..< 2 { for dx in 0 ..< 2 {
                let yuv = rgbToYuv(rgb(rgba, width, x + dx, y + dy), color)
                cb += yuv.1; cr += yuv.2
            }}
            let i = (y / 2) * uvStride + x
            uvWords[i] = q10(cb * 0.25) << 6; uvWords[i + 1] = q10(cr * 0.25) << 6
        }}
    }

    private static func writeV210(
        _ rgba: [Float], color: AVFoundationRecordingRequest.Color, into buffer: CVPixelBuffer
    ) throws {
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw AVFoundationRecordingError.writerFailed }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer) / 4
        let words = base.assumingMemoryBound(to: UInt32.self)
        for y in 0 ..< height { for group in 0 ..< (width + 5) / 6 {
            var ys = [UInt32](repeating: 0, count: 6), cb = [UInt32](repeating: 0, count: 3), cr = cb
            for pair in 0 ..< 3 {
                let x0 = min(width - 1, group * 6 + pair * 2), x1 = min(width - 1, x0 + 1)
                let a = rgbToYuv(rgb(rgba, width, x0, y), color), b = rgbToYuv(rgb(rgba, width, x1, y), color)
                ys[pair * 2] = UInt32(q10(a.0)); ys[pair * 2 + 1] = UInt32(q10(b.0))
                cb[pair] = UInt32(q10((a.1 + b.1) * 0.5)); cr[pair] = UInt32(q10((a.2 + b.2) * 0.5))
            }
            let o = y * stride + group * 4
            words[o] = cb[0] | ys[0] << 10 | cr[0] << 20
            words[o + 1] = ys[1] | cb[1] << 10 | ys[2] << 20
            words[o + 2] = cr[1] | ys[3] << 10 | cb[2] << 20
            words[o + 3] = ys[4] | cr[2] << 10 | ys[5] << 20
        }}
    }

    private static func writeRGBAHalf(_ rgba: [Float], into buffer: CVPixelBuffer) throws {
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw AVFoundationRecordingError.writerFailed }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer) / 2
        let words = base.assumingMemoryBound(to: UInt16.self)
        for y in 0 ..< height { for x in 0 ..< width { for c in 0 ..< 4 {
            words[y * stride + x * 4 + c] = Float16(rgba[(y * width + x) * 4 + c]).bitPattern
        }}}
    }

    private static func decode(
        _ url: URL, _ request: AVFoundationRecordingRequest
    ) throws -> [AVFoundationRecordingFrame] {
        let asset = AVURLAsset(url: url)
        let reader = try AVAssetReader(asset: asset)
        guard let track = try awaitValue({ try await asset.loadTracks(withMediaType: .video) }).first
        else { throw AVFoundationRecordingError.readerFailed }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat(for: request.codec),
        ])
        guard reader.canAdd(output) else { throw AVFoundationRecordingError.readerFailed }
        reader.add(output)
        guard reader.startReading() else { throw AVFoundationRecordingError.readerFailed }
        var frames: [AVFoundationRecordingFrame] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { throw AVFoundationRecordingError.readerFailed }
            frames.append(.init(
                frameIndex: request.firstFrameIndex + Int64(frames.count),
                rgba: try readRGBA(buffer, request.codec, request.color)
            ))
        }
        guard reader.status == .completed else { throw AVFoundationRecordingError.readerFailed }
        return frames
    }

    private static func readRGBA(
        _ buffer: CVPixelBuffer, _ codec: AVFoundationRecordingRequest.Codec,
        _ color: AVFoundationRecordingRequest.Color
    ) throws -> [Float] {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        var out = [Float](repeating: 1, count: width * height * 4)
        switch codec {
        case .h264High8:
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw AVFoundationRecordingError.readerFailed }
            let stride = CVPixelBufferGetBytesPerRow(buffer)
            for y in 0 ..< height { for x in 0 ..< width {
                let p = base.advanced(by: y * stride + x * 4).assumingMemoryBound(to: UInt8.self), i = (y * width + x) * 4
                out[i] = Float(p[2]) / 255; out[i + 1] = Float(p[1]) / 255; out[i + 2] = Float(p[0]) / 255
            }}
        case .hevcMain10:
            guard CVPixelBufferGetPlaneCount(buffer) == 2,
                  let yBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
                  let uvBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)
            else { throw AVFoundationRecordingError.readerFailed }
            let ys = yBase.assumingMemoryBound(to: UInt16.self), uvs = uvBase.assumingMemoryBound(to: UInt16.self)
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) / 2, uvStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1) / 2
            for y in 0 ..< height { for x in 0 ..< width {
                let uvi = (y / 2) * uvStride + (x / 2) * 2
                put(yuvToRgb((Float(ys[y * yStride + x] >> 6) / 1023, Float(uvs[uvi] >> 6) / 1023, Float(uvs[uvi + 1] >> 6) / 1023), color), (y * width + x) * 4, &out)
            }}
        case .proRes422HQ:
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw AVFoundationRecordingError.readerFailed }
            let stride = CVPixelBufferGetBytesPerRow(buffer) / 4, words = base.assumingMemoryBound(to: UInt32.self)
            for y in 0 ..< height { for g in 0 ..< (width + 5) / 6 {
                let o = y * stride + g * 4, a = words[o], b = words[o + 1], c = words[o + 2], d = words[o + 3]
                let yy = [(a >> 10) & 1023, b & 1023, (b >> 20) & 1023, (c >> 10) & 1023, d & 1023, (d >> 20) & 1023]
                let cb = [a & 1023, (b >> 10) & 1023, (c >> 20) & 1023], cr = [(a >> 20) & 1023, c & 1023, (d >> 10) & 1023]
                for local in 0 ..< 6 where g * 6 + local < width {
                    put(yuvToRgb((Float(yy[local]) / 1023, Float(cb[local / 2]) / 1023, Float(cr[local / 2]) / 1023), color), (y * width + g * 6 + local) * 4, &out)
                }
            }}
        case .proRes4444:
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw AVFoundationRecordingError.readerFailed }
            let stride = CVPixelBufferGetBytesPerRow(buffer) / 2, words = base.assumingMemoryBound(to: UInt16.self)
            for y in 0 ..< height { for x in 0 ..< width { for channel in 0 ..< 4 {
                out[(y * width + x) * 4 + channel] = Float(Float16(bitPattern: words[y * stride + x * 4 + channel]))
            }}}
        }
        return out
    }

    private static func rgb(_ rgba: [Float], _ width: Int, _ x: Int, _ y: Int) -> SIMD3<Float> {
        let i = (y * width + x) * 4
        return [rgba[i], rgba[i + 1], rgba[i + 2]]
    }

    private static func rgbToYuv(_ rgb: SIMD3<Float>, _ color: AVFoundationRecordingRequest.Color) -> (Float, Float, Float) {
        let kr: Float = color == .rec709 ? 0.2126 : 0.2627, kb: Float = color == .rec709 ? 0.0722 : 0.0593, kg = 1 - kr - kb
        let y = kr * rgb.x + kg * rgb.y + kb * rgb.z
        return (y, (rgb.z - y) / (2 * (1 - kb)) + 0.5, (rgb.x - y) / (2 * (1 - kr)) + 0.5)
    }

    private static func yuvToRgb(_ yuv: (Float, Float, Float), _ color: AVFoundationRecordingRequest.Color) -> SIMD3<Float> {
        let kr: Float = color == .rec709 ? 0.2126 : 0.2627, kb: Float = color == .rec709 ? 0.0722 : 0.0593, kg = 1 - kr - kb
        let cb = yuv.1 - 0.5, cr = yuv.2 - 0.5, r = yuv.0 + 2 * (1 - kr) * cr, b = yuv.0 + 2 * (1 - kb) * cb
        return [r, (yuv.0 - kr * r - kb * b) / kg, b]
    }

    private static func put(_ rgb: SIMD3<Float>, _ i: Int, _ rgba: inout [Float]) {
        rgba[i] = min(1, max(0, rgb.x)); rgba[i + 1] = min(1, max(0, rgb.y)); rgba[i + 2] = min(1, max(0, rgb.z)); rgba[i + 3] = 1
    }

    private static func q8(_ value: Float) -> UInt8 { UInt8((min(1, max(0, value)) * 255).rounded()) }
    private static func q10(_ value: Float) -> UInt16 { UInt16((min(1, max(0, value)) * 1023).rounded()) }

    private static func awaitValue<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) throws -> T {
        let semaphore = DispatchSemaphore(value: 0), result = LockedResult<T>()
        Task { do { result.store(.success(try await operation())) } catch { result.store(.failure(error)) }; semaphore.signal() }
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
