import Foundation
import Testing
@testable import ScreenSimulationNative

@Test func rotationXYZProjectionRoundTripsAndExpressesMinusFiveDegrees() {
    let authored = [12.5, -5.0, 27.5]
    let quaternion = PoseRotationProjection.quaternion(fromDegrees: authored)
    let restored = PoseRotationProjection.degrees(from: quaternion)

    #expect(quaternion.count == 4)
    for index in authored.indices {
        #expect(abs(restored[index] - authored[index]) < 1e-10)
    }

    let minusFiveY = PoseRotationProjection.quaternion(fromDegrees: [0, -5, 0])
    #expect(abs(minusFiveY[0]) < 1e-12)
    #expect(abs(minusFiveY[1] - sin(-5 * .pi / 360)) < 1e-12)
    #expect(abs(minusFiveY[2]) < 1e-12)
    #expect(abs(minusFiveY[3] - cos(-5 * .pi / 360)) < 1e-12)
}

@Test func capturePresetCatalogComesFromRustAndAppliesAnImmutableSnapshot() throws {
    let catalog = try CapturePresetDefinition.catalog()
    #expect(catalog.count == 2)
    #expect(catalog.contains { $0.name.contains("ARRI ALEXA 35") })
    #expect(catalog.contains { $0.name.contains("iPhone 16e") })

    let device = try #require(try RustDeviceCatalog.builtIns().first)
    let cover = try #require(try RustCoverGlassCatalog.builtIns().first {
        $0.id == device.defaultCoverGlassPresetID
    })
    var authored = try PhysicalPipelineAuthoringState.seeded(device: device, coverGlass: cover)
    let iphone = try #require(catalog.first { $0.name.contains("iPhone 16e") })
    iphone.apply(to: &authored, frameRate: 25)

    #expect(abs(authored.sceneLens.focalLengthMillimeters - 4.2) < 0.001)
    #expect(authored.sensor.nativeWidth == 8_064)
    #expect(authored.sensor.nativeHeight == 6_048)
    #expect(authored.shutterMotion.temporalSamples > 0)
    #expect(authored.shutterMotion.openOffsetNumerator < 0)
    #expect(authored.shutterMotion.closeOffsetNumerator > 0)
}

@Test func modelPreviewExposesTimelineEditableZoomAndSelectedQualityFrameExport() throws {
    let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let source = tests.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/ScreenSimulationNative/ContentView.swift")
    let text = try String(contentsOf: source, encoding: .utf8)

    #expect(text.contains("model.setZoomPercentage"))
    #expect(text.contains("Label(\"Guardar frame\""))
    #expect(text.contains("model.renderCurrentFrame()"))
    #expect(text.contains("NativeTimelineView("))
    #expect(text.contains("Divider()\n            transport\n            Divider()"))
}
