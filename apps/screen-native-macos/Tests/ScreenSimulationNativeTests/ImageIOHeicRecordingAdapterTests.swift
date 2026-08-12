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
    let output = try RecordingPhaseExecutor.output(
        cameraRendered: camera,
        transformID: RecordingPhaseExecutor.iphoneHeicOutputTransformID,
        display: display
    )
    let codec = try RecordingPhaseExecutor.codec(
        output: output,
        profileID: RecordingPhaseExecutor.iphoneHeicProfileID,
        character: 1,
        display: display
    )
    #expect(output.frame.texture !== camera.texture)
    #expect(codec.frame.texture !== output.frame.texture)
    #expect(codec.encodedBytes > 0)
    #expect(codec.encodedSHA256Hex.count == 64)
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
