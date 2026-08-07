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

@Test func lookAtProducesTheOnlyQuaternionAndCanDeriveTheSameTarget() {
    let position = [0.2, -0.1, 1.0]
    let target = [0.0, 0.0, 0.0]
    let quaternion = PoseRotationProjection.quaternionLooking(from: position, to: target)
    let distance = PoseRotationProjection.distance(position, target)
    let restored = PoseRotationProjection.target(
        from: position, quaternion: quaternion, distance: distance
    )
    for index in 0..<3 {
        #expect(abs(restored[index] - target[index]) < 1e-10)
    }
}

@Test func shutterAngleTimeAndReadoutRemainLinkedInStandardUnits() {
    var shutter = PhysicalPipelineAuthoringState.ShutterMotion()
    ShutterPresentation.setAngle(180, fps: 24, in: &shutter)
    #expect(abs(ShutterPresentation.exposureSeconds(shutter) - 1.0 / 48.0) < 1e-9)
    #expect(abs(ShutterPresentation.angle(shutter, fps: 24) - 180) < 1e-4)

    ShutterPresentation.setExposureSeconds(1.0 / 96.0, in: &shutter)
    #expect(abs(ShutterPresentation.angle(shutter, fps: 24) - 90) < 1e-4)

    ShutterPresentation.setReadoutMilliseconds(12, in: &shutter)
    #expect(abs(ShutterPresentation.readoutMilliseconds(shutter) - 12) < 1e-9)
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

    let selection = try PhysicalFrameSelection(
        frameIndex: 17,
        timeNumerator: 17,
        timeDenominator: 25
    )
    let orchestration = try authored.orchestration(for: selection)
    let openSeconds = Double(orchestration.shutter.open.numerator)
        / Double(orchestration.shutter.open.denominator)
    let closeSeconds = Double(orchestration.shutter.close.numerator)
        / Double(orchestration.shutter.close.denominator)
    #expect(openSeconds < closeSeconds)
    #expect(orchestration.cameraPose.position.z == Float(authored.cameraPose.position[2]))
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

@Test @MainActor func capturePresetAndCameraPoseInvalidateTheInteractivePreview() throws {
    let workspace = WorkspaceModel()
    let device = try #require(try RustDeviceCatalog.builtIns().first)
    let cover = try #require(try RustCoverGlassCatalog.builtIns().first {
        $0.id == device.defaultCoverGlassPresetID
    })
    workspace.selectModelDevice(device, coverGlass: cover)

    let initialRevision = workspace.physicalModel.parameterRevision
    let iphone = try #require(workspace.capturePresets.first { $0.name.contains("iPhone 16e") })
    workspace.selectCapturePreset(iphone, undoManager: nil)
    #expect(workspace.physicalModel.parameterRevision == initialRevision + 1)
    #expect(workspace.modelPreviewSurfaceAspect == 8_064.0 / 6_048.0)
    #expect(workspace.modelNativeOutputDescription == "Captura 8064×6048")

    let arri = try #require(workspace.capturePresets.first { $0.name.contains("ARRI") })
    workspace.selectCapturePreset(arri, undoManager: nil)
    let arriSensor = arri.parameters.sensor
    #expect(workspace.modelPreviewSurfaceAspect
        == Double(arriSensor.native_width) / Double(arriSensor.native_height))
    #expect(workspace.modelNativeOutputDescription
        == "Captura \(arriSensor.native_width)×\(arriSensor.native_height)")

    workspace.selectCapturePreset(iphone, undoManager: nil)

    let presetRevision = workspace.physicalModel.parameterRevision
    workspace.updatePhysicalAuthoring(undoManager: nil) {
        $0.cameraPose.position[2] = 0.5
    }
    #expect(workspace.physicalModel.parameterRevision == presetRevision + 1)

    let state = try #require(workspace.physicalAuthoringState)
    let selection = try PhysicalFrameSelection(
        frameIndex: 3,
        timeNumerator: 3,
        timeDenominator: 24
    )
    let orchestration = try state.orchestration(for: selection)
    #expect(orchestration.cameraPose.position.z == 0.5)
}
