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
    authored.environment.rotationXDegrees = -12.5
    authored.environment.rotationYDegrees = 37.5
    authored.coverGlass.agMicrotextureCharacterStrength = 1.25
    authored.coverGlass.agMicrotextureRMSSlope = 0.07
    authored.coverGlass.agMicrotextureCorrelationLengthMicrometers = 24
    authored.coverGlass.agMicrotextureAnisotropy = 0.3
    authored.coverGlass.agMicrotextureSeed = 4_294_967_295
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
    #expect(snapshot.environment.rotation_x_degrees == -12.5)
    #expect(snapshot.environment.rotation_y_degrees == 37.5)
    #expect(snapshot.cover.ag_microtexture_character_strength == 1.25)
    #expect(snapshot.cover.ag_microtexture_rms_slope == 0.07)
    #expect(snapshot.cover.ag_microtexture_correlation_length_micrometers == 24)
    #expect(snapshot.cover.ag_microtexture_anisotropy == 0.3)
    #expect(snapshot.cover.ag_microtexture_seed == UInt32.max)
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

@Test @MainActor func customSceneDeviceSurvivesLaterAuthoringChanges() throws {
    let preset = try #require(try RustDeviceCatalog.builtIns().first)
    let cover = try #require(try RustCoverGlassCatalog.builtIns().first {
        $0.id == preset.defaultCoverGlassPresetID
    })
    let workspace = WorkspaceModel()
    workspace.selectModelDevice(preset, coverGlass: cover)

    var custom = preset
    custom.id = UUID().uuidString
    custom.name = "Device personalizado"
    custom.nativeWidth += 17
    workspace.selectModelDevice(custom, coverGlass: cover)
    workspace.handleTestIntent(.setScalar(controlID: "moire-intensity", value: 0.5))

    #expect(workspace.modelDeviceDefinition?.id == custom.id)
    #expect(workspace.modelDeviceDefinition?.nativeWidth == custom.nativeWidth)
}

@Test @MainActor func everyAuthoredChangeReturnsNativeToSetupAndMaterializesPlacement() throws {
    let device = try #require(try RustDeviceCatalog.builtIns().first)
    let cover = try #require(try RustCoverGlassCatalog.builtIns().first {
        $0.id == device.defaultCoverGlassPresetID
    })
    let workspace = WorkspaceModel()
    workspace.selectModelDevice(device, coverGlass: cover)
    workspace.setTestPageActive(true)

    workspace.handleTestIntent(.setChoice(
        controlID: "preview-quality",
        optionID: "native"
    ))
    #expect(workspace.physicalModel.quality == .native)

    workspace.handleTestIntent(.setScalar(
        controlID: "moire-intensity",
        value: 0
    ))
    #expect(workspace.physicalModel.quality == .setup)
    guard case let .choice(qualityAfterMoire) = try #require(
        workspace.testPresentation?.previewControls.first
    ) else {
        Issue.record("La calidad de Preview debe continuar publicada como selección.")
        return
    }
    #expect(qualityAfterMoire.selectedID == "setup")

    workspace.handleTestIntent(.setChoice(
        controlID: "preview-quality",
        optionID: "native"
    ))
    workspace.handleTestIntent(.setChoice(
        controlID: "placement",
        optionID: "fill-crop"
    ))
    #expect(workspace.physicalModel.quality == .setup)
    #expect(workspace.sourcePlacement == .fillCrop)
    guard case let .choice(qualityAfterPlacement) = try #require(
        workspace.testPresentation?.previewControls.first
    ) else {
        Issue.record("La calidad de Preview debe continuar publicada como selección.")
        return
    }
    #expect(qualityAfterPlacement.selectedID == "setup")
}

@Test @MainActor func changingBuiltInDeviceAppliesItsAuthoredDefaultsAtomically() throws {
    let devices = try RustDeviceCatalog.builtIns()
    let phone = try #require(devices.first { $0.id == "lcd-phone-4_7-retina" })
    let asus = try #require(devices.first { $0.id == "lcd-asus-proart-pa329cv" })
    let covers = try RustCoverGlassCatalog.builtIns()
    let phoneCover = try #require(covers.first { $0.id == phone.defaultCoverGlassPresetID })
    let asusCover = try #require(covers.first { $0.id == asus.defaultCoverGlassPresetID })
    let workspace = WorkspaceModel()

    workspace.selectModelDevice(phone, coverGlass: phoneCover)
    workspace.selectModelDevice(asus, coverGlass: asusCover)

    #expect(workspace.errorMessage == nil)
    #expect(workspace.modelDeviceDefinition?.id == asus.id)
    #expect(workspace.modelDeviceDefinition?.colorModeID == "srgb")
    #expect(workspace.modelDeviceDefinition?.whiteLevelNits == 350)
    #expect(workspace.modelDeviceDefinition?.panelUniformity.characterStrength
        == asus.panelUniformity.characterStrength)
    #expect(workspace.modelDeviceDefinition?.panelLightSpread.characterStrength
        == asus.panelLightSpread.characterStrength)
}
