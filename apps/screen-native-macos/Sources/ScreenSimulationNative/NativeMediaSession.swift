@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO

struct NativeMediaSample: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let time: CMTime
}

struct NativeSourceInfo: Sendable {
    let name: String
    let detail: String
    let duration: CMTime
    let frameRate: Double
    let frameCount: Int
    let hasAudio: Bool
}

@MainActor
final class NativeMediaSession {
    enum Source {
        case none
        case video(player: AVPlayer, output: AVPlayerItemVideoOutput)
        case images([URL])
    }

    private(set) var source: Source = .none
    private(set) var info: NativeSourceInfo?
    private(set) var sourceURL: URL?
    private var videoAsset: AVURLAsset?
    private var videoTrack: AVAssetTrack?
    private var videoPixelAttributes: [String: Any] = [:]

    var isPlaying: Bool {
        if case let .video(player, _) = source { return player.rate != 0 }
        return false
    }

    func openVideo(_ url: URL, hasAlpha: Bool) async throws -> NativeSourceInfo {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NativeMediaError.unreadable(url.lastPathComponent)
        }
        let duration = try await asset.load(.duration)
        let nominalRate = Double(try await track.load(.nominalFrameRate))
        let frameRate = nominalRate > 0 ? nominalRate : 24
        let audio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
        let pixelFormat: OSType = hasAlpha
            ? kCVPixelFormatType_32BGRA
            : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
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
            detail: "Video · \(Int(frameRate.rounded())) fps · \(audio ? "audio" : "sin audio")",
            duration: duration,
            frameRate: frameRate,
            frameCount: count,
            hasAudio: audio
        )
        info = result
        output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
        return result
    }

    func openImages(_ urls: [URL], frameRate: Double = 24) throws -> NativeSourceInfo {
        let ordered = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !ordered.isEmpty else { throw NativeMediaError.invalidRaster }
        source = .images(ordered)
        sourceURL = nil
        videoAsset = nil
        videoTrack = nil
        videoPixelAttributes = [:]
        let duration = CMTime(value: CMTimeValue(ordered.count), timescale: CMTimeScale(frameRate.rounded()))
        let result = NativeSourceInfo(
            name: ordered.count == 1 ? ordered[0].lastPathComponent : "\(ordered[0].deletingPathExtension().lastPathComponent)…",
            detail: ordered.count == 1 ? "Imagen" : "Secuencia · \(ordered.count) frames · \(Int(frameRate)) fps",
            duration: duration,
            frameRate: frameRate,
            frameCount: ordered.count,
            hasAudio: false
        )
        info = result
        return result
    }

    func play() {
        if case let .video(player, _) = source { player.play() }
    }

    func pause() {
        if case let .video(player, _) = source { player.pause() }
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
            return NativeMediaSample(pixelBuffer: buffer, time: displayTime.isValid ? displayTime : player.currentTime())
        case let .images(urls):
            let fps = info?.frameRate ?? 24
            let seconds = max(0, requested?.seconds ?? 0)
            let index = min(urls.count - 1, Int((seconds * fps).rounded(.down)))
            return NativeMediaSample(
                pixelBuffer: try Self.imagePixelBuffer(urls[index]),
                time: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps.rounded()))
            )
        }
    }

    func exactSample(at requested: CMTime) async throws -> NativeMediaSample? {
        if case .images = source { return try currentSample(at: requested) }
        guard let asset = videoAsset, let track = videoTrack else { return nil }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track, outputSettings: videoPixelAttributes
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw NativeMediaError.invalidRaster }
        reader.add(output)
        let duration = CMTime(seconds: 1 / (info?.frameRate ?? 24), preferredTimescale: 60_000)
        reader.timeRange = CMTimeRange(start: bounded(requested), duration: duration)
        guard reader.startReading(),
              let sample = output.copyNextSampleBuffer(),
              let buffer = CMSampleBufferGetImageBuffer(sample)
        else { throw NativeMediaError.unreadable("frame \(requested.seconds)") }
        return NativeMediaSample(
            pixelBuffer: buffer,
            time: CMSampleBufferGetPresentationTimeStamp(sample)
        )
    }

    func time(forFrame frame: Int) -> CMTime {
        let rate = info?.frameRate ?? 24
        return CMTime(value: CMTimeValue(max(0, frame)), timescale: CMTimeScale(rate.rounded()))
    }

    private func bounded(_ time: CMTime) -> CMTime {
        guard let duration = info?.duration, duration.isNumeric else { return max(.zero, time) }
        return min(max(.zero, time), duration)
    }

    private static func imagePixelBuffer(_ url: URL) throws -> CVPixelBuffer {
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
}
