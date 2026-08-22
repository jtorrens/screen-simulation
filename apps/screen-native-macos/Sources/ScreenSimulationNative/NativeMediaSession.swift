@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import ScreenPhysicalBridge
import StudioMedia

struct NativeMediaSample: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let time: CMTime
}

struct NativeMediaSampleIdentity: Hashable, Sendable {
    let frameIndex: Int
}

struct NativeSourceInfo: Sendable {
    let name: String
    let detail: String
    let duration: CMTime
    let exactFrameRate: ExactFrameRate
    let frameCount: Int
    let hasAudio: Bool

    var frameRate: Double { exactFrameRate.framesPerSecond }
}

@MainActor
final class NativeFFmpegSource {
    let url: URL
    let colorModel: StudioSignalColorModel
    let matrix: StudioSignalMatrix
    let range: StudioSignalRange
    private(set) var currentTime: CMTime = .zero
    private var playbackStartedAt: CFTimeInterval?

    init(
        url: URL,
        colorModel: StudioSignalColorModel,
        matrix: StudioSignalMatrix,
        range: StudioSignalRange
    ) {
        self.url = url
        self.colorModel = colorModel
        self.matrix = matrix
        self.range = range
    }

    var isPlaying: Bool { playbackStartedAt != nil }

    func play() {
        guard playbackStartedAt == nil else { return }
        playbackStartedAt = CACurrentMediaTime()
    }

    func pause() {
        currentTime = resolvedCurrentTime()
        playbackStartedAt = nil
    }

    func seek(to time: CMTime) {
        currentTime = time
        playbackStartedAt = playbackStartedAt.map { _ in CACurrentMediaTime() }
    }

    func resolvedCurrentTime() -> CMTime {
        guard let playbackStartedAt else { return currentTime }
        return CMTimeAdd(
            currentTime,
            CMTime(seconds: CACurrentMediaTime() - playbackStartedAt, preferredTimescale: 60_000)
        )
    }
}

@MainActor
final class NativeMediaSession {
    enum Source {
        case none
        case video(player: AVPlayer, output: AVPlayerItemVideoOutput)
        case ffmpeg(NativeFFmpegSource)
        case images([URL])
    }

    private(set) var source: Source = .none
    private(set) var info: NativeSourceInfo?
    private(set) var sourceURL: URL?
    private var videoAsset: AVURLAsset?
    private var videoTrack: AVAssetTrack?
    private var videoPixelAttributes: [String: Any] = [:]

    var sourceURLs: [URL] {
        switch source {
        case .none: []
        case .video: sourceURL.map { [$0] } ?? []
        case .ffmpeg: sourceURL.map { [$0] } ?? []
        case let .images(urls): urls
        }
    }

    func reset() {
        if case let .video(player, _) = source { player.pause() }
        source = .none
        info = nil
        sourceURL = nil
        videoAsset = nil
        videoTrack = nil
        videoPixelAttributes = [:]
    }

    var isPlaying: Bool {
        if case let .video(player, _) = source { return player.rate != 0 }
        if case let .ffmpeg(source) = source { return source.isPlaying }
        return false
    }

    func openVideo(
        _ url: URL,
        hasAlpha: Bool,
        colorModel: StudioSignalColorModel,
        matrix: StudioSignalMatrix,
        decodedRange: StudioSignalRange
    ) async throws -> NativeSourceInfo {
        let asset = AVURLAsset(url: url)
        let isPlayable = try await asset.load(.isPlayable)
        if !isPlayable {
            return try openFFmpegVideo(
                url, colorModel: colorModel, matrix: matrix, range: decodedRange
            )
        }
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NativeMediaError.unreadable(url.lastPathComponent)
        }
        let duration = try await asset.load(.duration)
        let minimumFrameDuration = try await track.load(.minFrameDuration)
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let displaySize = naturalSize.applying(preferredTransform)
        guard minimumFrameDuration.isNumeric,
              minimumFrameDuration.value > 0,
              minimumFrameDuration.timescale > 0,
              let rateNumerator = UInt32(exactly: minimumFrameDuration.timescale),
              let rateDenominator = UInt32(exactly: minimumFrameDuration.value)
        else { throw NativeMediaError.invalidFrameRate }
        let exactFrameRate = try ExactFrameRate(
            numerator: rateNumerator,
            denominator: rateDenominator
        )
        let frameRate = exactFrameRate.framesPerSecond
        let audio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
        let pixelFormat: OSType
        if colorModel == .rgb {
            pixelFormat = kCVPixelFormatType_64RGBAHalf
        } else if hasAlpha {
            pixelFormat = kCVPixelFormatType_4444AYpCbCr16
        } else {
            pixelFormat = decodedRange == .full
                ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
                : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: pixelFormat),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        let item = AVPlayerItem(asset: asset)
        item.add(output)
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        source = .video(player: player, output: output)
        sourceURL = url
        videoAsset = asset
        videoTrack = track
        videoPixelAttributes = attributes
        let count = max(1, Int((duration.seconds * frameRate).rounded()))
        let result = NativeSourceInfo(
            name: url.lastPathComponent,
            detail: "Video · \(Int(abs(displaySize.width))) × \(Int(abs(displaySize.height))) · \(Int(frameRate.rounded())) fps · \(audio ? "audio" : "sin audio")",
            duration: duration,
            exactFrameRate: exactFrameRate,
            frameCount: count,
            hasAudio: audio
        )
        info = result
        output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
        return result
    }

    func openImages(
        _ urls: [URL],
        frameRate: ExactFrameRate
    ) throws -> NativeSourceInfo {
        let ordered = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !ordered.isEmpty else { throw NativeMediaError.invalidRaster }
        source = .images(ordered)
        sourceURL = nil
        videoAsset = nil
        videoTrack = nil
        videoPixelAttributes = [:]
        let duration = CMTime(
            value: CMTimeValue(ordered.count) * CMTimeValue(frameRate.denominator),
            timescale: CMTimeScale(frameRate.numerator)
        )
        let result = NativeSourceInfo(
            name: ordered.count == 1 ? ordered[0].lastPathComponent : "\(ordered[0].deletingPathExtension().lastPathComponent)…",
            detail: ordered.count == 1 ? "Imagen" : "Secuencia · \(ordered.count) frames · \(frameRate.framesPerSecond.formatted()) fps",
            duration: duration,
            exactFrameRate: frameRate,
            frameCount: ordered.count,
            hasAudio: false
        )
        info = result
        return result
    }

    func play() {
        if case let .video(player, _) = source { player.play() }
        if case let .ffmpeg(source) = source { source.play() }
    }

    func pause() {
        if case let .video(player, _) = source { player.pause() }
        if case let .ffmpeg(source) = source { source.pause() }
    }

    func seek(to time: CMTime) async throws {
        if case let .video(player, output) = source {
            let target = bounded(time)
            player.seek(
                to: target, toleranceBefore: .zero, toleranceAfter: .zero,
                completionHandler: { _ in }
            )
            output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.01)
        }
        if case let .ffmpeg(source) = source {
            source.seek(to: bounded(time))
        }
    }

    func prime() async {
        if case let .video(player, output) = source {
            output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
            await player.preroll(atRate: 1)
        }
    }

    func currentSample(at requested: CMTime? = nil) throws -> NativeMediaSample? {
        switch source {
        case .none:
            return nil
        case let .video(player, output):
            let time = requested ?? (player.rate == 0
                ? player.currentTime()
                : output.itemTime(forHostTime: CACurrentMediaTime()))
            var displayTime = CMTime.invalid
            guard let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayTime) else {
                return nil
            }
            return NativeMediaSample(pixelBuffer: buffer, time: time)
        case let .ffmpeg(source):
            let time = requested ?? source.resolvedCurrentTime()
            let decoded = try NativeFFmpegMedia.decode(
                url: source.url, time: bounded(time), colorModel: source.colorModel,
                matrix: source.matrix, range: source.range
            )
            return NativeMediaSample(
                pixelBuffer: try Self.decodedPixelBuffer(decoded), time: bounded(time)
            )
        case let .images(urls):
            guard let rate = info?.exactFrameRate else {
                throw NativeMediaError.invalidFrameRate
            }
            let fps = rate.framesPerSecond
            let seconds = max(0, requested?.seconds ?? 0)
            let index = min(urls.count - 1, Int((seconds * fps).rounded(.down)))
            return NativeMediaSample(
                pixelBuffer: try Self.imagePixelBuffer(urls[index]),
                time: CMTime(
                    value: CMTimeValue(index) * CMTimeValue(rate.denominator),
                    timescale: CMTimeScale(rate.numerator)
                )
            )
        }
    }

    func exactSample(at requested: CMTime) async throws -> NativeMediaSample? {
        let decodeTime = resolvedSampleTime(at: requested)
        if case .images = source {
            guard let sample = try currentSample(at: decodeTime) else {
                return nil
            }
            return NativeMediaSample(pixelBuffer: sample.pixelBuffer, time: requested)
        }
        if case let .ffmpeg(source) = source {
            let decoded = try NativeFFmpegMedia.decode(
                url: source.url, time: decodeTime, colorModel: source.colorModel,
                matrix: source.matrix, range: source.range
            )
            return NativeMediaSample(
                pixelBuffer: try Self.decodedPixelBuffer(decoded), time: requested
            )
        }
        guard let asset = videoAsset, let track = videoTrack else { return nil }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track, outputSettings: videoPixelAttributes
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw NativeMediaError.invalidRaster }
        reader.add(output)
        guard let rate = info?.exactFrameRate else {
            throw NativeMediaError.invalidFrameRate
        }
        let duration = CMTime(
            value: CMTimeValue(rate.denominator),
            timescale: CMTimeScale(rate.numerator)
        )
        reader.timeRange = CMTimeRange(start: decodeTime, duration: duration)
        guard reader.startReading(),
              let sample = output.copyNextSampleBuffer(),
              let buffer = CMSampleBufferGetImageBuffer(sample)
        else { throw NativeMediaError.unreadable("frame \(requested.seconds)") }
        return NativeMediaSample(
            pixelBuffer: buffer,
            // The decoded image is retained at the media boundary, but this sample
            // still represents the exact scene time requested by Application.
            time: requested
        )
    }

    func time(forFrame frame: Int) -> CMTime {
        guard let rate = info?.exactFrameRate else { return .invalid }
        return CMTime(
            value: CMTimeValue(max(0, frame)) * CMTimeValue(rate.denominator),
            timescale: CMTimeScale(rate.numerator)
        )
    }

    func sampleIdentity(at requested: CMTime) -> NativeMediaSampleIdentity? {
        guard let info else { return nil }
        return Self.sampleIdentity(
            at: requested,
            frameCount: info.frameCount,
            exactFrameRate: info.exactFrameRate
        )
    }

    private func resolvedSampleTime(at requested: CMTime) -> CMTime {
        guard let identity = sampleIdentity(at: requested), let info else {
            return max(.zero, requested)
        }
        return CMTime(
            value: CMTimeValue(identity.frameIndex)
                * CMTimeValue(info.exactFrameRate.denominator),
            timescale: CMTimeScale(info.exactFrameRate.numerator)
        )
    }

    private func bounded(_ time: CMTime) -> CMTime {
        guard let duration = info?.duration, duration.isNumeric else { return max(.zero, time) }
        return min(max(.zero, time), duration)
    }

    private func retainedDecodeTime(_ requested: CMTime) -> CMTime {
        guard let info else { return max(.zero, requested) }
        return Self.retainedDecodeTime(
            requested,
            frameCount: info.frameCount,
            exactFrameRate: info.exactFrameRate
        )
    }

    static func retainedDecodeTime(
        _ requested: CMTime,
        frameCount: Int,
        exactFrameRate: ExactFrameRate
    ) -> CMTime {
        let lastFrame = CMTime(
            value: CMTimeValue(max(0, frameCount - 1))
                * CMTimeValue(exactFrameRate.denominator),
            timescale: CMTimeScale(exactFrameRate.numerator)
        )
        return min(max(.zero, requested), lastFrame)
    }

    static func sampleIdentity(
        at requested: CMTime,
        frameCount: Int,
        exactFrameRate: ExactFrameRate
    ) -> NativeMediaSampleIdentity {
        let retained = retainedDecodeTime(
            requested,
            frameCount: frameCount,
            exactFrameRate: exactFrameRate
        )
        let cadenceTicks = CMTimeConvertScale(
            retained,
            timescale: CMTimeScale(exactFrameRate.numerator),
            method: .roundTowardNegativeInfinity
        ).value
        let frame = min(
            max(0, frameCount - 1),
            max(0, Int(cadenceTicks / CMTimeValue(exactFrameRate.denominator)))
        )
        return NativeMediaSampleIdentity(frameIndex: frame)
    }

    private static func imagePixelBuffer(_ url: URL) throws -> CVPixelBuffer {
        if url.pathExtension.lowercased() == "exr" {
            return try openEXRPixelBuffer(url)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw NativeMediaError.unreadable(url.lastPathComponent) }
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        guard CVPixelBufferCreate(
            nil, image.width, image.height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &buffer
        ) == kCVReturnSuccess, let buffer else { throw NativeMediaError.invalidRaster }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { throw NativeMediaError.invalidRaster }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    private func openFFmpegVideo(
        _ url: URL,
        colorModel: StudioSignalColorModel,
        matrix: StudioSignalMatrix,
        range: StudioSignalRange
    ) throws -> NativeSourceInfo {
        let decoded = try NativeFFmpegMedia.probe(url: url)
        let source = NativeFFmpegSource(
            url: url, colorModel: colorModel, matrix: matrix, range: range
        )
        self.source = .ffmpeg(source)
        sourceURL = url
        videoAsset = nil
        videoTrack = nil
        videoPixelAttributes = [:]
        let result = NativeSourceInfo(
            name: url.lastPathComponent,
            detail: "Video FFmpeg · \(decoded.width) × \(decoded.height) · \(Int(decoded.exactFrameRate.framesPerSecond.rounded())) fps · sin audio",
            duration: decoded.duration,
            exactFrameRate: decoded.exactFrameRate,
            frameCount: decoded.frameCount,
            hasAudio: false
        )
        info = result
        return result
    }

    private static func decodedPixelBuffer(_ decoded: DecodedNativeFrame) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        guard CVPixelBufferCreate(
            nil, decoded.width, decoded.height, kCVPixelFormatType_64RGBAHalf,
            attributes as CFDictionary, &buffer
        ) == kCVReturnSuccess, let buffer else { throw NativeMediaError.invalidRaster }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw NativeMediaError.invalidRaster }
        let rowStride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float16>.stride
        let destination = base.assumingMemoryBound(to: Float16.self)
        for row in 0 ..< decoded.height {
            let sourceStart = row * decoded.width * 4
            let destinationStart = row * rowStride
            for column in 0 ..< decoded.width * 4 {
                destination[destinationStart + column] = Float16(decoded.rgba[sourceStart + column])
            }
        }
        return buffer
    }

    private static func openEXRPixelBuffer(_ url: URL) throws -> CVPixelBuffer {
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
        guard UnsafeBufferPointer(start: pixels, count: count).allSatisfy(\.isFinite) else {
            throw NativeMediaError.unreadable("\(url.lastPathComponent) contiene muestras no finitas")
        }
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:],
        ]
        guard CVPixelBufferCreate(
            nil, Int(width), Int(height), kCVPixelFormatType_64RGBAHalf,
            attributes as CFDictionary, &buffer
        ) == kCVReturnSuccess, let buffer else { throw NativeMediaError.invalidRaster }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else {
            throw NativeMediaError.invalidRaster
        }
        let source = UnsafeBufferPointer(start: pixels, count: count)
        let rowStride = CVPixelBufferGetBytesPerRow(buffer) / MemoryLayout<Float16>.stride
        let destination = base.assumingMemoryBound(to: Float16.self)
        for row in 0 ..< Int(height) {
            for column in 0 ..< Int(width) * 4 {
                destination[row * rowStride + column] = Float16(source[row * Int(width) * 4 + column])
            }
        }
        return buffer
    }
}
