import Foundation
import CoreGraphics
import StudioColor
import Testing
@testable import ScreenSimulationNative

/// Optional review publication from the before/after headless optical fixtures.
/// Input is explicitly little-endian RGBA32F ACEScg, 256×160; no inferred IDT.
@Test @MainActor func optionalFrontalRenderReviewPNGs() throws {
    guard let path = ProcessInfo.processInfo.environment["SCREEN_FRONTAL_REVIEW_DIR"] else { return }
    let directory = URL(fileURLWithPath: path, isDirectory: true)
    let display = try StudioColorMetalDisplay()
    let input = try #require(StudioColorInputTransform.catalog.first { $0.id == "acescg" })
    let output = try #require(StudioColorOutputTransform.catalog.first { $0.id == "aces2-srgb-sdr-100" })
    for name in ["before-front", "after-front", "before-oblique", "after-oblique"] {
        let data = try Data(contentsOf: directory.appendingPathComponent(name + ".rgba"))
        try #require(data.count == 256 * 160 * 16)
        let floats = data.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 4).map {
                Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
            }
        }
        let finite = floats.allSatisfy { $0.isFinite }
        try #require(finite)
        let frame = try display.makeACEScgFrame(width: 256, height: 160,
            encodedRGBA: floats, input: input, alpha: .premultiplied)
        let pixels = try display.renderRGBA16(frame, output: output)
        let metadata = try JSONSerialization.data(withJSONObject: [
            "diagnostic": name, "input": "acescg", "output": output.id,
            "dof": "disabled", "resolution": "256x160"
        ], options: [.sortedKeys])
        let png = try FrameCheckPNG.encode(rgba16: pixels, width: 256, height: 160,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB), metadata: metadata)
        try png.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
    }
}
