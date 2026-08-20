import CoreGraphics
import Foundation
import ImageIO
import StudioColor
import Testing
import UniformTypeIdentifiers
@testable import ScreenSimulationNative

@Test @MainActor func checkpointMaterializesTheResolvedColorModeAsLosslessHalfFloat() throws {
    let display = try StudioColorMetalDisplay()
    let input = try #require(StudioColorInputTransform.catalog.first {
        $0.id == "srgb-encoded-rec709"
    })
    let outputSignal = try #require(StudioColorMode.catalog.first { $0.id == "srgb" })
    let source = try display.makeACEScgFrame(
        width: 2,
        height: 1,
        encodedRGBA: [0, 0.18, 1, 1, 0.9, 0.5, 0.1, 1],
        input: input,
        alpha: .straight
    )
    let checkpoint = try DeviceSignalCheckpoint.prepare(
        sourceACEScg: source,
        inputTransform: input,
        outputSignal: outputSignal,
        alphaInterpretation: "straight",
        sourceAdjustment: .neutral,
        display: display
    )

    #expect(checkpoint.metadata.inputTransformID == "srgb-encoded-rec709")
    #expect(checkpoint.metadata.inputReferenceDomain == "displayReferred")
    #expect(checkpoint.metadata.outputSignalID == "srgb")
    #expect(checkpoint.metadata.feederOutputTransformID == "device-srgb-colorimetric")

    let package = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeviceSignalCheckpoint-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: package) }
    try checkpoint.write(to: package, display: display)

    let decoded = try JSONDecoder().decode(
        DeviceSignalCheckpointMetadata.self,
        from: Data(contentsOf: package.appendingPathComponent("checkpoint.json"))
    )
    let json = try #require(
        JSONSerialization.jsonObject(
            with: Data(contentsOf: package.appendingPathComponent("checkpoint.json"))
        ) as? [String: Any]
    )
    #expect(json["inputTransformID"] as? String == "srgb-encoded-rec709")
    #expect(json["outputSignalID"] as? String == "srgb")
    #expect(json["feederOutputTransformID"] as? String == "device-srgb-colorimetric")
    try decoded.validate()
    #expect(decoded == checkpoint.metadata)
    #expect(
        try Data(contentsOf: package.appendingPathComponent("rgba16f.bin")).count
            == 2 * 1 * 4 * MemoryLayout<UInt16>.size
    )
    let payload = try DeviceSignalCheckpointPayload.read(from: package)
    #expect(payload.metadata == checkpoint.metadata)
    #expect(payload.rgba.count == 8)

    var unknownFieldJSON = json
    unknownFieldJSON["legacyTransform"] = "forbidden"
    try JSONSerialization.data(withJSONObject: unknownFieldJSON).write(
        to: package.appendingPathComponent("checkpoint.json"),
        options: .atomic
    )
    #expect(throws: DeviceSignalCheckpointError.self) {
        try DeviceSignalCheckpointPayload.read(from: package)
    }
}

@Test @MainActor func optionalComparisonExportUsesTheExactNativeCheckpointRoute() async throws {
    guard let exportDirectory = ProcessInfo.processInfo.environment[
        "SCREEN_FEEDER_SIGNAL_COMPARISON_DIR"
    ] else { return }

    let sourceURL = repositoryRoot()
        .appendingPathComponent("apps/screen-desktop/assets/frequency-moire-reference.png")
    let decoded = try await NativeMediaDecoder.decode(url: sourceURL, time: .zero)
    let display = try StudioColorMetalDisplay()
    let input = try #require(StudioColorInputTransform.catalog.first {
        $0.id == "srgb-encoded-rec709"
    })
    let outputSignal = try #require(StudioColorMode.catalog.first { $0.id == "srgb" })
    let source = try display.makeACEScgFrame(
        width: decoded.width,
        height: decoded.height,
        encodedRGBA: decoded.rgba,
        input: input,
        alpha: .ignore
    )
    let checkpoint = try DeviceSignalCheckpoint.prepare(
        sourceACEScg: source,
        inputTransform: input,
        outputSignal: outputSignal,
        alphaInterpretation: "ignore",
        sourceAdjustment: .neutral,
        display: display
    )

    let directory = URL(fileURLWithPath: exportDirectory, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    try checkpoint.write(
        to: directory.appendingPathComponent("nuevo-feeder-signal.feedersignal"),
        display: display
    )
    let values = try display.readLinearRGBA(checkpoint.deviceSignal)
    let rgba8 = values.map { UInt8(($0.clamped(to: 0 ... 1) * 255).rounded()) }
    try diagnosticPNG(rgba8, width: decoded.width, height: decoded.height).write(
        to: directory.appendingPathComponent("nuevo-feeder-signal.png"),
        options: .atomic
    )
}

private func repositoryRoot() -> URL {
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<4 { directory.deleteLastPathComponent() }
    return directory
}

private func diagnosticPNG(_ rgba8: [UInt8], width: Int, height: Int) throws -> Data {
    guard rgba8.count == width * height * 4,
          let provider = CGDataProvider(data: Data(rgba8) as CFData),
          let image = CGImage(
              width: width,
              height: height,
              bitsPerComponent: 8,
              bitsPerPixel: 32,
              bytesPerRow: width * 4,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
              provider: provider,
              decode: nil,
              shouldInterpolate: false,
              intent: .defaultIntent
          )
    else { throw DeviceSignalCheckpointError.invalidRaster }

    let encoded = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        encoded,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else { throw DeviceSignalCheckpointError.invalidRaster }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw DeviceSignalCheckpointError.invalidRaster
    }
    return encoded as Data
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
