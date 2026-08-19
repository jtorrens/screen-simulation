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

@Test @MainActor func workspaceMaintainsIndependentMultiLevelUndoAndRedo() throws {
    let device = try #require(try RustDeviceCatalog.builtIns().first)
    let cover = try #require(try RustCoverGlassCatalog.builtIns().first {
        $0.id == device.defaultCoverGlassPresetID
    })
    let workspace = WorkspaceModel()
    workspace.selectModelDevice(device, coverGlass: cover)
    let undo = UndoManager()

    workspace.updatePhysicalAuthoring(undoManager: undo) {
        $0.sceneLens.focalLengthMillimeters = 65
    }
    workspace.updatePhysicalAuthoring(undoManager: undo) {
        $0.sceneLens.focalLengthMillimeters = 85
    }
    #expect(workspace.physicalPipelineState?.parameters.scene_geometry_lens.focal_length_millimeters == 85)

    undo.undo()
    #expect(workspace.physicalPipelineState?.parameters.scene_geometry_lens.focal_length_millimeters == 65)
    undo.undo()
    #expect(workspace.physicalPipelineState?.parameters.scene_geometry_lens.focal_length_millimeters == 50)
    #expect(undo.canRedo)

    undo.redo()
    #expect(workspace.physicalPipelineState?.parameters.scene_geometry_lens.focal_length_millimeters == 65)
    undo.redo()
    #expect(workspace.physicalPipelineState?.parameters.scene_geometry_lens.focal_length_millimeters == 85)
}

@Test @MainActor func customSceneDeviceSurvivesLaterAuthoringChanges() throws {
    let preset = try #require(try RustDeviceCatalog.builtIns().first)
    let cover = try #require(try RustCoverGlassCatalog.builtIns().first {
        $0.id == preset.defaultCoverGlassPresetID
    })
    var custom = preset
    custom.id = UUID().uuidString
    custom.name = "Device personalizado"
    custom.nativeWidth += 17
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = try GlobalLibraryStore(documentURL: root.appendingPathComponent("library.json"))
    var library = try store.load()
    library.devices.append(.init(value: custom, isLocked: false))
    try store.save(library)
    let workspace = WorkspaceModel(globalLibraryStore: store)
    workspace.selectModelDevice(preset, coverGlass: cover)
    workspace.selectModelDevice(custom, coverGlass: cover)
    workspace.handleTestIntent(.setScalar(controlID: "moire-intensity", value: 0.5))

    #expect(workspace.modelDeviceDefinition?.id == custom.id)
    #expect(workspace.modelDeviceDefinition?.nativeWidth == custom.nativeWidth)
}

@Test @MainActor func globalLibraryEditRematerializesTheCompleteActiveSceneAndKeepsOverrides() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-live-library-refresh-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GlobalLibraryStore(documentURL: root.appendingPathComponent("library.json"))
    var library = try store.load()
    let device = try #require(library.devices.first?.value)
    let cover = try #require(library.coverGlasses.first(where: {
        $0.id == device.defaultCoverGlassPresetID
    })?.value)
    let workspace = WorkspaceModel(globalLibraryStore: store)
    workspace.selectModelDevice(device, coverGlass: cover)
    let authoredWhite = device.minimumWhiteLuminance
        + (device.maximumWhiteLuminance - device.minimumWhiteLuminance) * 0.75
    workspace.handleTestIntent(.setScalar(
        controlID: "white-luminance",
        value: authoredWhite
    ))
    let cameraID = try #require(workspace.selectedCapturePresetID)
    let priorSensorWidth = try #require(
        workspace.physicalAuthoringState?.sceneLens.sensorWidthMillimeters
    )
    #expect(try workspace.captureSavedScene().snapshot.authoring.profiles.captureID == cameraID)

    let deviceIndex = try #require(library.devices.firstIndex { $0.id == device.id })
    let cameraIndex = try #require(library.cameras.firstIndex { $0.id == cameraID })
    library.devices[deviceIndex].value.nativeWidth += 101
    library.devices[deviceIndex].value.nativeHeight += 53
    library.devices[deviceIndex].value.activeWidthMeters += 0.01
    library.devices[deviceIndex].value.activeHeightMeters += 0.02
    library.cameras[cameraIndex].value.gateWidthMillimeters *= 1.1
    try store.save(library)

    workspace.refreshActiveSceneFromGlobalLibrary()

    #expect(workspace.errorMessage == nil)
    #expect(workspace.modelDeviceDefinition?.nativeWidth
        == library.devices[deviceIndex].value.nativeWidth)
    #expect(workspace.modelDeviceDefinition?.nativeHeight
        == library.devices[deviceIndex].value.nativeHeight)
    #expect(workspace.modelDeviceDefinition?.activeWidthMeters
        == library.devices[deviceIndex].value.activeWidthMeters)
    #expect(workspace.modelDeviceDefinition?.activeHeightMeters
        == library.devices[deviceIndex].value.activeHeightMeters)
    #expect(workspace.capturePresets.first(where: { $0.id == cameraID })?.gateWidthMillimeters
        == library.cameras[cameraIndex].value.gateWidthMillimeters)
    #expect(abs(
        (workspace.physicalAuthoringState?.sceneLens.sensorWidthMillimeters ?? 0)
            - priorSensorWidth * 1.1
    ) < 1e-6)
    #expect(workspace.modelDeviceDefinition?.whiteLevelNits == authoredWhite)
    #expect(try workspace.captureSavedScene().snapshot.authoring.overrides
        .contains(.scalar("white-luminance", authoredWhite)))

    let materialized = try #require(workspace.modelDeviceDefinition)
    library.devices.removeAll { $0.id == device.id }
    try store.save(library)
    workspace.errorMessage = nil
    workspace.refreshActiveSceneFromGlobalLibrary()
    #expect(workspace.modelDeviceDefinition == materialized)
    #expect(workspace.errorMessage?.contains(device.id) == true)
}

@Test @MainActor func selectingAsusDerivedPhoneMaterializesItsAuthoredLuminance() throws {
    let devices = try RustDeviceCatalog.builtIns()
    let phone = try #require(devices.first { $0.id == "lcd-phone-4_7-retina" })
    let asus = try #require(devices.first { $0.id == "lcd-asus-proart-pa329cv" })
    let covers = try RustCoverGlassCatalog.builtIns()
    let phoneCover = try #require(covers.first { $0.id == phone.defaultCoverGlassPresetID })
    let asusCover = try #require(covers.first { $0.id == asus.defaultCoverGlassPresetID })
    var custom = asus
    custom.id = UUID().uuidString.lowercased()
    custom.name = "ASUS con proporciones Phone"
    custom.nativeWidth = 700
    custom.nativeHeight = 1_400
    custom.activeWidthMeters = 0.1
    custom.activeHeightMeters = 0.2
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = try GlobalLibraryStore(documentURL: root.appendingPathComponent("library.json"))
    var library = try store.load()
    library.devices.append(.init(value: custom, isLocked: false))
    try store.save(library)
    let workspace = WorkspaceModel(globalLibraryStore: store)
    workspace.selectModelDevice(phone, coverGlass: phoneCover)
    workspace.selectModelDevice(custom, coverGlass: asusCover)
    workspace.handleTestIntent(.setScalar(controlID: "moire-intensity", value: 0.5))

    #expect(workspace.errorMessage == nil)
    #expect(workspace.modelDeviceDefinition?.id == custom.id)
    #expect(workspace.modelDeviceDefinition?.nativeWidth == 700)
    #expect(workspace.modelDeviceDefinition?.nativeHeight == 1_400)
    #expect(workspace.modelDeviceDefinition?.whiteLevelNits == 350)
    #expect(workspace.modelDeviceDefinition?.panelUniformity.characterStrength
        == custom.panelUniformity.characterStrength)
    #expect(workspace.modelDeviceDefinition?.panelLightSpread.characterStrength
        == custom.panelLightSpread.characterStrength)
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

@Test @MainActor func customCameraLensAndEnvironmentUseTheSameGlobalLibraryAuthority() throws {
    let devices = try RustDeviceCatalog.builtIns()
    let covers = try RustCoverGlassCatalog.builtIns()
    let device = try #require(devices.first)
    let cover = try #require(covers.first { $0.id == device.defaultCoverGlassPresetID })
    var lens = try #require(try LensProfileDefinition.builtIns().first)
    lens.id = UUID().uuidString.lowercased()
    lens.name = "Lente de biblioteca"
    lens.nominalFocalLengthMillimeters = 73
    lens.radialDistortion = [0.031, -0.004, 0.0002]
    var camera = try #require(try CameraProfileDefinition.builtIns().first)
    camera.id = UUID().uuidString.lowercased()
    camera.name = "Cámara de biblioteca"
    camera.defaultLensID = lens.id
    camera.compatibleLensIDs = [lens.id]
    camera.gateWidthMillimeters = 31.2
    camera.defaultFStop = 5.6
    var environment = try #require(try EnvironmentProfileDefinition.builtIns().first)
    environment.id = UUID().uuidString.lowercased()
    environment.name = "Entorno de biblioteca"
    environment.environment.ambientRadianceACEScg = [12, 13, 14]

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let store = try GlobalLibraryStore(documentURL: root.appendingPathComponent("library.json"))
    try store.save(.init(
        devices: devices,
        coverGlasses: covers,
        cameras: (try CameraProfileDefinition.builtIns()) + [camera],
        lenses: (try LensProfileDefinition.builtIns()) + [lens],
        environments: (try EnvironmentProfileDefinition.builtIns()) + [environment]
    ))
    let workspace = WorkspaceModel(globalLibraryStore: store)
    workspace.selectModelDevice(device, coverGlass: cover)
    workspace.setTestPageActive(true)
    workspace.handleTestIntent(.setChoice(controlID: "capture-preset", optionID: camera.id))
    workspace.handleTestIntent(.setChoice(controlID: "environment-source", optionID: environment.id))

    #expect(workspace.errorMessage == nil)
    #expect(workspace.selectedCapturePresetID == camera.id)
    #expect(workspace.selectedLensPresetID == lens.id)
    #expect(workspace.physicalAuthoringState?.sceneLens.focalLengthMillimeters == 73)
    #expect(workspace.physicalAuthoringState?.sceneLens.sensorWidthMillimeters == 31.2)
    #expect(workspace.physicalAuthoringState?.sceneLens.radialDistortion == lens.radialDistortion)
    #expect(workspace.physicalAuthoringState?.environment.ambientRadianceACEScg == [12, 13, 14])
}
