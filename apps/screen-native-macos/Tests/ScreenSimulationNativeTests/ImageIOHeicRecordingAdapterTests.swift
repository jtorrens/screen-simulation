import Foundation
import CoreGraphics
import ImageIO
import Metal
import StudioColor
import Testing
import UniformTypeIdentifiers
@testable import ScreenSimulationNative

@MainActor
@Test func recordingExecutorPublishesDistinctOutputAndCodecArtifacts() throws {
    let display = try StudioColorMetalDisplay()
    let device = try #require(MTLCreateSystemDefaultDevice())
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba32Float, width: 64, height: 32, mipmapped: false
    )
    descriptor.storageMode = .shared
    descriptor.usage = [.shaderRead]
    let texture = try #require(device.makeTexture(descriptor: descriptor))
    var pixels = [Float](repeating: 1, count: 64 * 32 * 4)
    for index in stride(from: 0, to: pixels.count, by: 4) {
        pixels[index] = Float(index % 251) / 250
        pixels[index + 1] = 0.35
        pixels[index + 2] = 0.8
    }
    pixels.withUnsafeBytes {
        texture.replace(
            region: MTLRegionMake2D(0, 0, 64, 32), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: 64 * 4 * MemoryLayout<Float>.size
        )
    }
    let camera = StudioColorMetalFrame(texture: texture)
    let delivery = try RecordingPhaseExecutor.delivery(
        cameraRendered: camera, width: 64, height: 32,
        placementID: "one-to-one", backgroundID: "transparent", display: display
    )
    let output = try RecordingPhaseExecutor.output(
        delivery: delivery,
        transformID: RecordingPhaseExecutor.iphoneHeicOutputTransformID,
        display: display
    )
    let codec = try RecordingPhaseExecutor.codec(
        output: output,
        profileID: RecordingPhaseExecutor.iphoneHeicProfileID,
        character: 1,
        outputTransformID: RecordingPhaseExecutor.iphoneHeicOutputTransformID,
        display: display
    )
    #expect(output.frame.texture !== camera.texture)
    #expect(codec.frame.texture !== output.frame.texture)
    #expect(codec.encodedBytes > 0)
    #expect(codec.encodedSHA256Hex.count == 64)
}

@MainActor
@Test func opaqueProResCodecPreservesTheIndependentPhysicalMatte() throws {
    let width = 96, height = 64
    let display = try StudioColorMetalDisplay()
    let device = try #require(MTLCreateSystemDefaultDevice())
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false
    )
    descriptor.storageMode = .shared
    descriptor.usage = [.shaderRead]
    let texture = try #require(device.makeTexture(descriptor: descriptor))
    var pixels = [Float](repeating: 0, count: width * height * 4)
    let mattes: [Float] = [0, 0.5, 1]
    for pixel in 0 ..< width * height {
        let offset = pixel * 4
        pixels[offset] = 0.18
        pixels[offset + 1] = 0.08
        pixels[offset + 2] = 0.03
        pixels[offset + 3] = mattes[pixel % mattes.count]
    }
    pixels.withUnsafeBytes {
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: width * 4 * MemoryLayout<Float>.size
        )
    }
    let delivery = try RecordingPhaseExecutor.delivery(
        cameraRendered: StudioColorMetalFrame(texture: texture), width: width, height: height,
        placementID: "one-to-one", backgroundID: "black", display: display
    )
    let output = try RecordingPhaseExecutor.output(
        delivery: delivery,
        transformID: "generic-rec2100-pq-recording-full-v1",
        display: display
    )
    let codec = try RecordingPhaseExecutor.codec(
        output: output,
        profileID: "generic-prores-422-hq-v1",
        character: 1,
        outputTransformID: "generic-rec2100-pq-recording-full-v1",
        display: display
    )
    let authoredDeliveryPixels = try display.readLinearRGBA(delivery.frame)
    let compositeDeliveryPixels = try display.readLinearRGBA(delivery.compositionFrame)
    let outputPixels = try display.readLinearRGBA(output.frame)
    let decodedPixels = try display.readLinearRGBA(codec.frame)
    for pixel in 0 ..< width * height {
        let expected = mattes[pixel % mattes.count]
        // A black Delivery background owns opaque output alpha, but it cannot replace
        // the physical occlusion matte used by Reference composition.
        #expect(authoredDeliveryPixels[pixel * 4 + 3] == 1)
        #expect(delivery.physicalMatte[pixel] == expected)
        #expect(compositeDeliveryPixels[pixel * 4 + 3] == expected)
        #expect(outputPixels[pixel * 4 + 3] == expected)
        #expect(decodedPixels[pixel * 4 + 3] == expected)
    }
    // Spill/additive RGB remains usable even where the matte is zero.
    #expect(decodedPixels[0] > 0)
    #expect(decodedPixels[1] > 0)
    #expect(codec.decodedRGBA8[3] == 0)
    #expect(codec.decodedRGBA8[7] == 128)
    #expect(codec.decodedRGBA8[11] == 255)
}

@Test func imageIOHeicAdapterExecutesOneRealIntraRoundTrip() throws {
    let width = 320
    let height = 192
    var rgba = [UInt8](repeating: 255, count: width * height * 4)
    for y in 0 ..< height {
        for x in 0 ..< width {
            let offset = (y * width + x) * 4
            let block = ((x / 16) + (y / 16)) & 1
            rgba[offset] = block == 0 ? UInt8(x * 255 / (width - 1)) : 12
            rgba[offset + 1] = block == 0 ? UInt8(y * 255 / (height - 1)) : 220
            rgba[offset + 2] = block == 0 ? 230 : UInt8((x + y) & 255)
        }
    }
    let result = try ImageIOHeicRecordingAdapter.roundTrip(ImageIOHeicStillRequest(
        profileID: "iphone-heic-photo-v1",
        width: width,
        height: height,
        quality: 0.82,
        colorSpace: .displayP3D65,
        rgba8: rgba
    ))
    #expect(result.profileID == "iphone-heic-photo-v1")
    #expect(result.width == width)
    #expect(result.height == height)
    #expect(result.rgba8.count == rgba.count)
    #expect(result.encodedBytes > 0)
    #expect(result.encodedSHA256.count == 32)
    #expect(result.rgba8 != rgba)
    #expect(stride(from: 3, to: result.rgba8.count, by: 4).allSatisfy {
        result.rgba8[$0] == 255
    })
}

@Test func imageIOJpegAdapterExecutesOneRealIntraRoundTrip() throws {
    let width = 96
    let height = 64
    var rgba = [UInt8](repeating: 255, count: width * height * 4)
    for index in stride(from: 0, to: rgba.count, by: 4) {
        rgba[index] = UInt8((index / 4) % 251)
        rgba[index + 1] = 96
        rgba[index + 2] = 210
    }
    let result = try ImageIOHeicRecordingAdapter.roundTrip(.init(
        profileID: "generic-jpeg-photo-v1",
        width: width,
        height: height,
        quality: 0.9,
        colorSpace: .rec709,
        rgba8: rgba
    ))
    #expect(result.profileID == "generic-jpeg-photo-v1")
    #expect(result.encodedBytes > 0)
    #expect(result.rgba8.count == rgba.count)
}

@Test func avFoundationRecordingAdapterExecutesAllBundledVideoProfiles() throws {
    let width = 96
    let height = 64
    var rgba = [UInt8](repeating: 255, count: width * height * 4)
    for index in stride(from: 0, to: rgba.count, by: 4) {
        rgba[index] = UInt8((index / 4) % 251)
        rgba[index + 1] = 128
        rgba[index + 2] = 220
    }
    let floatRGBA = rgba.map { Float($0) / 255 }
    for (codec, color) in [
        (AVFoundationRecordingRequest.Codec.h264High8, AVFoundationRecordingRequest.Color.rec709),
        (.hevcMain10, .rec2100PQ),
        (.proRes422HQ, .rec2100PQ),
        (.proRes4444, .rec2100PQ),
    ] {
        let result = try AVFoundationRecordingAdapter.roundTrip(.init(
            codec: codec,
            color: color,
            width: width,
            height: height,
            frameRateNumerator: 24,
            frameRateDenominator: 1,
            firstFrameIndex: 0,
            bitsPerSecond: 4_000_000,
            frames: [.init(frameIndex: 0, rgba: floatRGBA)]
        ))
        #expect(result.encodedData.count > 0)
        #expect(result.encodedSHA256.count == 32)
        #expect(result.frames.count == 1)
        #expect(result.frames[0].rgba.count == rgba.count)
    }
}

@MainActor
@Test func recordingOutputUsesTheExactDisplayP3SrgbTransferExpectedByImageIO() throws {
    let display = try StudioColorMetalDisplay()
    let device = try #require(MTLCreateSystemDefaultDevice())
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba32Float, width: 1, height: 1, mipmapped: false
    )
    descriptor.storageMode = .shared
    descriptor.usage = [.shaderRead]
    let texture = try #require(device.makeTexture(descriptor: descriptor))
    let source: [Float] = [0.18, 0.18, 0.18, 1]
    source.withUnsafeBytes {
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: 4 * MemoryLayout<Float>.size
        )
    }
    let delivery = try RecordingPhaseExecutor.delivery(
        cameraRendered: StudioColorMetalFrame(texture: texture), width: 1, height: 1,
        placementID: "one-to-one", backgroundID: "transparent", display: display
    )
    let output = try RecordingPhaseExecutor.output(
        delivery: delivery,
        transformID: RecordingPhaseExecutor.iphoneHeicOutputTransformID,
        display: display
    )
    let encoded = output.rgba8.map { Float($0) / 255 }
    let reference = try display.renderRGBA8(
        StudioColorMetalFrame(texture: texture),
        output: try #require(StudioColorOutputTransform.catalog.first {
            $0.id == "aces2-display-p3-sdr-100"
        })
    ).map { Float($0) / 255 }
    #expect(zip(encoded, reference).allSatisfy { abs($0 - $1) <= 1.0 / 255.0 })
}

@Test func imageIOHeicAdapterPublishesRequestedDiagnostic() throws {
    let environment = ProcessInfo.processInfo.environment
    guard let sourcePath = environment["SCREEN_HEIC_DIAGNOSTIC_SOURCE"],
          let outputDirectory = environment["SCREEN_HEIC_DIAGNOSTIC_OUTPUT"]
    else { return }
    let sourceURL = URL(fileURLWithPath: sourcePath)
    let outputURL = URL(fileURLWithPath: outputDirectory, isDirectory: true)
    let source = try Data(contentsOf: sourceURL)
    guard let imageSource = CGImageSourceCreateWithData(source as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    else { throw ImageIOHeicRecordingError.decodeFailed }
    let rgba = try rgba8(image)
    let result = try ImageIOHeicRecordingAdapter.roundTrip(ImageIOHeicStillRequest(
        profileID: "iphone-heic-photo-v1",
        width: image.width,
        height: image.height,
        quality: 0.82,
        colorSpace: .displayP3D65,
        rgba8: rgba
    ))
    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
    try result.encodedData.write(to: outputURL.appendingPathComponent("after-codec.heic"))
    try writePNG(
        result.rgba8,
        width: result.width,
        height: result.height,
        to: outputURL.appendingPathComponent("after-codec.png")
    )
    try writePNG(
        rgba,
        width: image.width,
        height: image.height,
        to: outputURL.appendingPathComponent("before-codec.png")
    )
    let manifest: [String: Any] = [
        "schema": "screen_heic_codec_diagnostic",
        "version": 1,
        "profileID": result.profileID,
        "quality": 0.82,
        "width": result.width,
        "height": result.height,
        "encodedBytes": result.encodedBytes,
        "encodedSHA256": result.encodedSHA256.map { String(format: "%02x", $0) }.joined(),
        "cameraRenderingIntent": [
            "exposureEV": 0.5,
            "contrast": 1.10,
            "saturation": 1.25,
            "temperatureKelvin": 6500,
            "tint": 0,
        ],
    ]
    try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        .write(to: outputURL.appendingPathComponent("codec-diagnostic.json"))
}

@MainActor
@Test func recordingColorDiagnosticPublishesUniformAndHighFrequencyCyan() throws {
    guard let outputDirectory = ProcessInfo.processInfo.environment[
        "SCREEN_RECORDING_COLOR_DIAGNOSTIC_DIR"
    ] else { return }
    let width = 512
    let height = 256
    var pixels = [Float](repeating: 1, count: width * height * 4)
    for y in 0 ..< height {
        for x in 0 ..< width {
            let offset = (y * width + x) * 4
            let cyan: Bool = x < width / 2 || ((x + y) & 1) == 0
            pixels[offset] = cyan ? 0.02 : 0.18
            pixels[offset + 1] = cyan ? 0.80 : 0.18
            pixels[offset + 2] = cyan ? 0.80 : 0.18
        }
    }
    let device = try #require(MTLCreateSystemDefaultDevice())
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false
    )
    descriptor.storageMode = .shared
    descriptor.usage = [.shaderRead]
    let texture = try #require(device.makeTexture(descriptor: descriptor))
    pixels.withUnsafeBytes {
        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: width * 4 * MemoryLayout<Float>.size
        )
    }
    let display = try StudioColorMetalDisplay()
    let delivery = try RecordingPhaseExecutor.delivery(
        cameraRendered: StudioColorMetalFrame(texture: texture), width: width, height: height,
        placementID: "one-to-one", backgroundID: "transparent", display: display
    )
    let output = try RecordingPhaseExecutor.output(
        delivery: delivery,
        transformID: RecordingPhaseExecutor.iphoneHeicOutputTransformID,
        display: display
    )
    let codec = try RecordingPhaseExecutor.codec(
        output: output,
        profileID: RecordingPhaseExecutor.iphoneHeicProfileID,
        character: 1,
        outputTransformID: RecordingPhaseExecutor.iphoneHeicOutputTransformID,
        display: display
    )
    let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try writePNG(
        output.rgba8, width: width, height: height,
        to: directory.appendingPathComponent("recording-output.png")
    )
    try writePNG(
        codec.decodedRGBA8, width: width, height: height,
        to: directory.appendingPathComponent("recording-codec-decoded.png")
    )
    try codec.encodedData.write(to: directory.appendingPathComponent("recording-codec.heic"))
    func meanChroma(_ rgba: [UInt8], xRange: Range<Int>) -> Double {
        var total = 0.0
        var count = 0
        for y in 0 ..< height {
            for x in xRange {
                let offset = (y * width + x) * 4
                let minimum = min(rgba[offset], rgba[offset + 1], rgba[offset + 2])
                let maximum = max(rgba[offset], rgba[offset + 1], rgba[offset + 2])
                total += Double(maximum - minimum) / 255
                count += 1
            }
        }
        return total / Double(count)
    }
    func horizontalColorContrast(_ rgba: [UInt8], xRange: Range<Int>) -> Double {
        var total = 0.0
        var count = 0
        for y in 0 ..< height {
            for x in xRange.dropFirst() {
                let left = (y * width + x - 1) * 4
                let right = left + 4
                for channel in 0 ..< 3 {
                    total += abs(Double(rgba[right + channel]) - Double(rgba[left + channel])) / 255
                    count += 1
                }
            }
        }
        return total / Double(count)
    }
    let manifest: [String: Any] = [
        "schema": "ScreenSimulation.RecordingColorDiagnostic",
        "version": 1,
        "recordingOutputTransformID": RecordingPhaseExecutor.iphoneHeicOutputTransformID,
        "recordingProfileID": RecordingPhaseExecutor.iphoneHeicProfileID,
        "quality": RecordingPhaseExecutor.calibratedHeicQuality,
        "encodedBytes": codec.encodedBytes,
        "encodedSHA256": codec.encodedSHA256Hex,
        "uniformCyan": [
            "beforeMeanChroma": meanChroma(output.rgba8, xRange: 0 ..< width / 2),
            "afterMeanChroma": meanChroma(codec.decodedRGBA8, xRange: 0 ..< width / 2),
        ],
        "onePixelCyanChecker": [
            "beforeMeanChroma": meanChroma(output.rgba8, xRange: width / 2 ..< width),
            "afterMeanChroma": meanChroma(codec.decodedRGBA8, xRange: width / 2 ..< width),
            "beforeHorizontalColorContrast": horizontalColorContrast(
                output.rgba8, xRange: width / 2 ..< width
            ),
            "afterHorizontalColorContrast": horizontalColorContrast(
                codec.decodedRGBA8, xRange: width / 2 ..< width
            ),
        ],
    ]
    try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("recording-color-diagnostic.json"))
}

@Test func imageIOHeicAdapterRejectsNonOpaqueInput() {
    #expect(throws: ImageIOHeicRecordingError.nonOpaqueInput) {
        try ImageIOHeicRecordingAdapter.roundTrip(ImageIOHeicStillRequest(
            profileID: "iphone-heic-photo-v1",
            width: 1,
            height: 1,
            quality: 0.82,
            colorSpace: .displayP3D65,
            rgba8: [1, 2, 3, 254]
        ))
    }
}

private func rgba8(_ image: CGImage) throws -> [UInt8] {
    var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let rendered = bytes.withUnsafeMutableBytes { storage in
        guard let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(
                data: storage.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: space,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
                    .union(.byteOrder32Big).rawValue
              )
        else { return false }
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return true
    }
    guard rendered else { throw ImageIOHeicRecordingError.decodeFailed }
    for alpha in stride(from: 3, to: bytes.count, by: 4) { bytes[alpha] = 255 }
    return bytes
}

private func writePNG(_ bytes: [UInt8], width: Int, height: Int, to url: URL) throws {
    guard let space = CGColorSpace(name: CGColorSpace.displayP3),
          let provider = CGDataProvider(data: Data(bytes) as CFData),
          let image = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
                .union(.byteOrder32Big),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .relativeColorimetric
          )
    else { throw ImageIOHeicRecordingError.decodeFailed }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        data,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else { throw ImageIOHeicRecordingError.encodeFailed }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw ImageIOHeicRecordingError.encodeFailed
    }
    try (data as Data).write(to: url)
}

@Test func imageIOHeicAdapterRejectsInvalidQualityAndRaster() {
    #expect(throws: ImageIOHeicRecordingError.invalidRequest) {
        try ImageIOHeicRecordingAdapter.roundTrip(ImageIOHeicStillRequest(
            profileID: "iphone-heic-photo-v1",
            width: 2,
            height: 1,
            quality: 1.1,
            colorSpace: .displayP3D65,
            rgba8: [0, 0, 0, 255]
        ))
    }
}
