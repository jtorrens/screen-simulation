import Foundation
import Testing
@testable import ScreenSimulationNative

@Test @MainActor func physicalAuthoringRoundTripsEverySnapshotDomainAndNativeUndo() async throws {
    let device = try #require(try RustDeviceCatalog.builtIns().first)
    let cover = try #require(try RustCoverGlassCatalog.builtIns().first {
        $0.id == device.defaultCoverGlassPresetID
    })
    var authored = try PhysicalPipelineAuthoringState.seeded(
        device: device,
        coverGlass: cover
    )
    authored.environment.rotationDegrees = 37.5
    authored.sceneLens.focalLengthMillimeters = 85
    authored.shutterMotion.temporalSamples = 8
    authored.sensor.nativeWidth = 1_920
    authored.sensor.nativeHeight = 1_080
    authored.sensor.readNoiseElectronsRMS = 3.5
    authored.develop.whiteBalance = [1.1, 1, 0.9]
    authored.cameraPose.position = [0.1, -0.2, 1.5]

    let data = try JSONEncoder().encode(authored)
    let restored = try JSONDecoder().decode(
        PhysicalPipelineAuthoringState.self,
        from: data
    )
    #expect(restored == authored)
    let snapshot = try restored.resolvedPipeline().parameters
    #expect(snapshot.environment.rotation_degrees == 37.5)
    #expect(snapshot.scene_geometry_lens.focal_length_millimeters == 85)
    #expect(snapshot.shutter_motion.temporal_samples == 8)
    #expect(snapshot.sensor_noise.native_width == 1_920)
    #expect(snapshot.sensor_noise.read_noise_electrons_rms == 3.5)
    #expect(snapshot.raw_develop.white_balance.0 == 1.1)

    let workspace = WorkspaceModel()
    workspace.selectModelDevice(device, coverGlass: cover)
    let undo = UndoManager()
    workspace.updatePhysicalAuthoring(undoManager: undo) {
        $0.sceneLens.focalLengthMillimeters = 85
    }
    #expect(workspace.physicalPipelineState?.parameters.scene_geometry_lens.focal_length_millimeters == 85)
    undo.undo()
    await Task.yield()
    #expect(workspace.physicalPipelineState?.parameters.scene_geometry_lens.focal_length_millimeters == 50)
}

@Test func everyAuthorableSnapshotGroupHasAnActiveModelUIBinding() throws {
    let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let source = tests.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/ScreenSimulationNative/ModelInspectorView.swift")
    let text = try String(contentsOf: source, encoding: .utf8)
    let requiredKeyPaths = [
        "\\.eotfGamma", "\\.blackLevelNits", "\\.whiteLevelNits",
        "\\.red", "\\.green", "\\.blue", "\\.white", "\\.angularEmissionPower",
        "\\.nativeWidth", "\\.nativeHeight", "\\.activeWidthMeters",
        "\\.activeHeightMeters", "\\.stripeLayout", "\\.blackMatrixFraction",
        "\\.panelLightSpread.coreRadiusMicrometers", "\\.panelLightSpread.coreWeight",
        "\\.panelLightSpread.tailRadiusMicrometers", "\\.panelLightSpread.tailWeight",
        "\\.residualFlickerPeriod.numerator", "\\.residualFlickerAmplitude",
        "\\.residualFlickerPhase.numerator", "\\.bandingPeriod.numerator",
        "\\.bandingOnDuration.numerator", "\\.bandingPhase.numerator", "\\.bandingAmount",
        "\\.coverGlass.thicknessMillimeters", "\\.coverGlass.refractiveIndex",
        "\\.coverGlass.antiReflectiveEfficiency", "\\.coverGlass.absorptionPerMillimeter",
        "\\.coverGlass.roughness", "\\.coverGlass.haze",
        "\\.environment.ambientRadianceACEScg", "\\.environment.keyRadianceACEScg",
        "\\.environment.keyDirectionLocal", "\\.environment.keyAngularRadiusDegrees",
        "\\.environment.rotationDegrees", "\\.environment.pattern",
        "\\.cameraPose.position", "\\.cameraPose.quaternion",
        "\\.screenPose.position", "\\.screenPose.quaternion",
        "\\.sceneLens.focalLengthMillimeters", "\\.sceneLens.sensorWidthMillimeters",
        "\\.sceneLens.sensorHeightMillimeters", "\\.sceneLens.lensShift",
        "\\.sceneLens.focusDistanceMeters", "\\.sceneLens.fStop",
        "\\.sceneLens.nearClipMeters", "\\.sceneLens.farClipMeters",
        "\\.sceneLens.radialDistortion", "\\.sceneLens.tangentialDistortion",
        "\\.sceneLens.longitudinalChromaticMeters", "\\.sceneLens.lateralChromaticScale",
        "\\.sceneLens.vignettingStrength", "\\.sceneLens.transmissionRGB",
        "\\.sceneLens.centerSoftnessMicrometers", "\\.sceneLens.edgeSoftnessMicrometers",
        "\\.shutterMotion.temporalSamples", "\\.shutterMotion.readoutKind",
        "\\.shutterMotion.readoutDurationNumerator", "\\.shutterMotion.readoutDurationDenominator",
        "\\.shutterMotion.readoutDirection", "\\.shutterMotion.neutralDensityStops",
        "\\.shutterMotion.noiseSeed", "\\.shutterMotion.openOffsetNumerator",
        "\\.shutterMotion.openOffsetDenominator", "\\.shutterMotion.closeOffsetNumerator",
        "\\.shutterMotion.closeOffsetDenominator", "\\.sensor.nativeWidth",
        "\\.sensor.nativeHeight", "\\.sensor.bayerPattern", "\\.sensor.acescgToSensor",
        "\\.sensor.saturationIlluminanceSeconds", "\\.sensor.fullWellElectrons",
        "\\.sensor.darkCurrentElectronsPerSecond", "\\.sensor.readNoiseElectronsRMS",
        "\\.sensor.analogGain", "\\.sensor.adcBits", "\\.develop.whiteBalance",
        "\\.develop.middleGrayIlluminanceSeconds", "\\.develop.exposureEV",
    ]
    for keyPath in requiredKeyPaths {
        #expect(text.contains(keyPath), "Missing active UI binding for \(keyPath)")
    }
    #expect(text.contains("Control amount de cabecera"))
    #expect(text.contains("PhysicalDerivedRow"))

    let controls = source.deletingLastPathComponent()
        .appendingPathComponent("PhysicalParameterControls.swift")
    let controlsText = try String(contentsOf: controls, encoding: .utf8)
    #expect(controlsText.contains("PhysicalParameterRestoreButton"))
    #expect(controlsText.contains("arrow.counterclockwise"))
    #expect(controlsText.contains("isModified: value != defaultValue"))
    #expect(text.contains(".toggleStyle(.switch)"))
    #expect(text.contains(".labelsHidden()"))
}
