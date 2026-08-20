import Foundation
import Testing
@testable import ScreenSimulationNative

@Test func captureCheckpointsOwnTheCameraRasterInsteadOfTheDeviceRaster() {
    let captureOwned: [PhysicalIntermediate] = [
        .sensorCollection, .sensorBloom, .sensorReadoutRaw,
        .developedACEScg, .cameraRenderedACEScg,
    ]
    for intermediate in PhysicalIntermediate.allCases {
        #expect(intermediate.usesCaptureRaster == captureOwned.contains(intermediate))
    }
    let camera = PhysicalIntermediate.cameraRenderedACEScg.nativeRasterSize(
        deviceWidth: 700, deviceHeight: 1_400,
        captureWidth: 4_608, captureHeight: 2_592
    )
    #expect(camera.width == 4_608)
    #expect(camera.height == 2_592)
    let panel = PhysicalIntermediate.panelEmission.nativeRasterSize(
        deviceWidth: 700, deviceHeight: 1_400,
        captureWidth: 4_608, captureHeight: 3_164
    )
    #expect(panel.width == 700)
    #expect(panel.height == 1_400)
}

@Test func importedGateSelectsTheLargestCenteredSensorCropWithoutScaling() throws {
    let window = try PhysicalActiveSensorWindow(
        fullWidth: 4_608,
        fullHeight: 3_164,
        gateWidth: 0.98 * 25.4,
        gateHeight: 0.55125 * 25.4
    )
    #expect(window.originX == 0)
    #expect(window.originY == 286)
    #expect(window.width == 4_608)
    #expect(window.height == 2_592)
    #expect(Double(window.width) / Double(window.height) == 16.0 / 9.0)
}

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

@Test func lookAtRotationsOrbitAtFixedDistanceAndPreserveRoll() {
    let target = [0.0, 0.0, 0.0]
    let distance = 2.0
    let authored = [20.0, -35.0, 15.0]
    let position = PoseRotationProjection.orbitPosition(
        around: target,
        distance: distance,
        rotationDegrees: authored
    )
    let quaternion = PoseRotationProjection.quaternionLooking(
        from: position,
        to: target,
        rollDegrees: authored[2]
    )
    let restored = PoseRotationProjection.lookAtOrbitDegrees(
        position: position,
        target: target,
        quaternion: quaternion
    )

    #expect(abs(PoseRotationProjection.distance(position, target) - distance) < 1e-10)
    for index in authored.indices {
        #expect(abs(restored[index] - authored[index]) < 1e-10)
    }

    let restoredTarget = PoseRotationProjection.target(
        from: position,
        quaternion: quaternion,
        distance: distance
    )
    for index in target.indices {
        #expect(abs(restoredTarget[index] - target[index]) < 1e-10)
    }
}

@Test func capturePresetCatalogComesFromRustAndAppliesAnImmutableSnapshot() throws {
    let catalog = try CapturePresetDefinition.catalog()
    #expect(catalog.count == 5)
    #expect(catalog.contains { $0.name.contains("ARRI ALEXA 35") })
    #expect(catalog.contains { $0.name.contains("iPhone 16e") })
    #expect(catalog.contains { $0.name.contains("Canon PowerShot A470") })
    #expect(catalog.contains { $0.name.contains("iPhone 14 Pro main") })
    #expect(catalog.contains { $0.name.contains("iPhone 14 Pro ultra-wide") })

    let device = try #require(try RustDeviceCatalog.builtIns().first)
    let cover = try #require(try RustCoverGlassCatalog.builtIns().first {
        $0.id == device.defaultCoverGlassPresetID
    })
    var authored = try PhysicalPipelineAuthoringState.seeded(device: device, coverGlass: cover)
    let iphone = try #require(catalog.first { $0.name.contains("iPhone 16e") })
    let lenses = try LensPresetDefinition.catalog()
    let integrated = try #require(lenses.first { $0.id == iphone.defaultLensID })
    #expect(iphone.lensAssociationPolicy == .fixed)
    #expect(iphone.compatibleLensIDs == [integrated.id])
    try iphone.applyCamera(
        rasterModeID: iphone.defaultRasterModeID,
        to: &authored,
        frameRate: 25
    )
    integrated.apply(to: &authored)

    #expect(abs(authored.sceneLens.focalLengthMillimeters - 4.2) < 0.001)
    #expect(authored.sensor.nativeWidth == 5_712)
    #expect(authored.sensor.nativeHeight == 4_284)
    #expect(authored.shutterMotion.temporalSamples > 0)
    #expect(authored.shutterMotion.openOffsetNumerator < 0)
    #expect(authored.shutterMotion.closeOffsetNumerator > 0)

    let selection = try PhysicalFrameSelection(
        frameIndex: 17,
        timeNumerator: 17,
        timeDenominator: 25,
        frameRateNumerator: 25,
        frameRateDenominator: 1
    )
    let orchestration = try authored.orchestration(for: selection)
    let openSeconds = Double(orchestration.shutter.open.numerator)
        / Double(orchestration.shutter.open.denominator)
    let closeSeconds = Double(orchestration.shutter.close.numerator)
        / Double(orchestration.shutter.close.denominator)
    #expect(openSeconds < closeSeconds)
    #expect(orchestration.cameraPose.position.z == Float(authored.cameraPose.position[2]))
}

@Test func sharedPreviewExposesTimelineEditableZoomAndFrameExport() throws {
    let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let source = tests.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/ScreenSimulationNative/ContentView.swift")
    let text = try String(contentsOf: source, encoding: .utf8)

    #expect(text.contains("model.setZoomPercentage"))
    #expect(text.contains("Button(\"Frame\", action: model.renderCurrentFrame)"))
    #expect(!text.contains("Recuperar ajustes"))
    #expect(!text.contains("importPhysicalSettings"))
    #expect(text.contains("model.renderCurrentFrame()"))
    #expect(text.contains("NativeTimelineView("))
    #expect(text.contains("Divider()\n            transport\n            Divider()"))
}

@Test func setupNavigationRejectsWheelMomentumAndKeepsTheDeviceBoundary() throws {
    let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let source = tests.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/ScreenSimulationNative/ContentView.swift")
    let text = try String(contentsOf: source, encoding: .utf8)

    #expect(text.contains("guard event.momentumPhase.isEmpty"))
    #expect(text.contains("flushCameraGestureChange()"))
    #expect(text.contains("model.physicalModel.quality == .environmentSetup"))
}

@Test func testAuthoringBeginsWithOneSourceAndColorRoute() throws {
    let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let source = tests.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/ScreenSimulationNative/ContentView.swift")
    let text = try String(contentsOf: source, encoding: .utf8)
    let start = try #require(text.range(of: "private var testSetupPanel"))
    let end = try #require(text.range(
        of: "private func interpretationLabel",
        range: start.upperBound..<text.endIndex
    ))
    let setup = text[start.lowerBound..<end.lowerBound]

    let sourceControls = try #require(setup.range(of: "Text(\"Fuente\")"))
    let color = try #require(setup.range(of: "Text(\"Interpretación de entrada\")"))
    let working = try #require(setup.range(of: "Text(\"Working space\")"))
    #expect(sourceControls.lowerBound < color.lowerBound)
    #expect(color.lowerBound < working.lowerBound)
    #expect(setup.contains("TestPhaseCard(label: \"Origen\")"))
    #expect(setup.contains("TestAuthoringView("))
    #expect(setup.contains("Button(\"Abrir archivo o secuencia…\""))
    #expect(setup.contains("if model.hasExternalSourceMedia"))
    #expect(setup.contains("Button(\"Quitar\", action: model.removeExternalSourceMedia)"))
    #expect(setup.contains("Picker(\"Patrón sintético\""))
    #expect(text.contains("TestPreviewControls("))
}

@Test @MainActor func syntheticSourceCannotBeRemovedAsExternalMedia() {
    let workspace = WorkspaceModel()
    #expect(workspace.hasExternalSourceMedia == false)

    workspace.removeExternalSourceMedia()

    #expect(workspace.hasExternalSourceMedia == false)
    #expect(workspace.sourceKindLabel == "Patrón sintético")
}

@Test @MainActor func removingExternalSourceActivatesTheSelectedSyntheticPattern() async {
    let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let media = repositoryRoot
        .appendingPathComponent("apps/screen-desktop/assets/editorial-text-reference.png")
    let workspace = WorkspaceModel()
    workspace.choosePattern(.frequencyMoireReference, undoManager: nil)

    await workspace.load([media], materializeImportInterpretation: false)
    #expect(workspace.hasExternalSourceMedia)

    workspace.removeExternalSourceMedia()

    #expect(workspace.hasExternalSourceMedia == false)
    #expect(workspace.selectedPattern == .frequencyMoireReference)
    #expect(workspace.sourceName == SyntheticPattern.frequencyMoireReference.label)
    #expect(workspace.sourceKindLabel == "Patrón sintético")
}

@Test func everySyntheticPatternDeclaresCompleteInputEvidence() {
    for pattern in SyntheticPattern.allCases {
        let evidence = pattern.sourceDetection
        #expect(evidence.proposedInputTransformID == "srgb-encoded-rec709")
        #expect(evidence.inputTransformProvenance == .proposed)
        #expect(evidence.alpha == .ignore)
        #expect(evidence.matrix == .bt709)
        #expect(evidence.range == .full)
        #expect(evidence.colorModel == .rgb)
    }
}

@Test func vfxComparisonPatternPreservesThePhotographedRaster() throws {
    let frame = try SyntheticPattern.vfxComparisonReference.frame()
    #expect(frame.width == 3_840)
    #expect(frame.height == 2_160)
    #expect(frame.rgba.count == 3_840 * 2_160 * 4)
    #expect(SyntheticPattern.vfxComparisonReference.authoredPlacementID == "one-to-one")
}

@Test @MainActor func choosingTheVfxReferenceAppliesItsAuthoredOneToOnePlacement() {
    let workspace = WorkspaceModel()

    workspace.choosePattern(.vfxComparisonReference, undoManager: nil)
    #expect(workspace.sourcePlacement == .oneToOne)
    #expect(workspace.sourceDetail.contains("3840 × 2160"))

    workspace.choosePattern(.editorialTextReference, undoManager: nil)
    #expect(workspace.sourcePlacement == .fit)
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
    #expect(workspace.physicalPreviewSurfaceAspect == 8_064.0 / 6_048.0)
    #expect(workspace.physicalNativeOutputDescription == "Captura 5712×4284")

    let arri = try #require(workspace.capturePresets.first { $0.name.contains("ARRI") })
    workspace.selectCapturePreset(arri, undoManager: nil)
    let arriSensor = arri.sensor
    #expect(workspace.physicalPreviewSurfaceAspect
        == Double(arriSensor.nativeWidth) / Double(arriSensor.nativeHeight))
    #expect(workspace.physicalNativeOutputDescription
        == "Captura \(arriSensor.nativeWidth)×\(arriSensor.nativeHeight)")

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
        timeDenominator: 24,
        frameRateNumerator: 24,
        frameRateDenominator: 1
    )
    let orchestration = try state.orchestration(for: selection)
    #expect(orchestration.cameraPose.position.z == 0.5)
}
