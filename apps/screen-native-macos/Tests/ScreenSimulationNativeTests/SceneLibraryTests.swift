import Foundation
import ScreenSimulationPresentation
import StudioColor
import StudioMedia
import Testing
@testable import ScreenSimulationNative

private func sceneAuthoring() throws -> SceneAuthoringDocument {
    let input = try #require(StudioColorInputTransform.catalog.first {
        $0.id == "srgb-encoded-rec709"
    })
    let output = try #require(StudioColorOutputTransform.catalog.first {
        $0.id == "aces2-srgb-sdr-100"
    })
    let device = try #require(try RustDeviceCatalog.builtIns().first)
    let selection = try RustTestAuthoringCoordinator.defaultSelection(
        inputTransformID: input.id, deviceID: device.id, frameRate: .fps24
    )
    let coverGlass = try #require(try RustCoverGlassCatalog.builtIns().first)
    return .init(
        profiles: .init(
            deviceID: device.id,
            coverGlassID: coverGlass.id,
            captureID: selection.capturePresetID,
            lensID: selection.lensPresetID,
            environmentID: selection.environmentSourceID,
            deliveryID: selection.deliveryPresetID,
            recordingID: selection.recordingProfileID
        ),
        overrides: [],
        modelOverrides: .init(screen: nil, stages: []),
        context: .init(
            sourceInputTransformID: input.id,
            sourceAlphaMode: StudioAlphaMode.ignore.rawValue,
            sourceColorModel: StudioSignalColorModel.rgb.rawValue,
            sourceYUVMatrix: StudioSignalMatrix.bt709.rawValue,
            sourceSignalRange: StudioSignalRange.full.rawValue,
            sourcePlacementID: "fit",
            previewOutputTransformID: output.id,
            previewPhaseID: "recording-codec",
            referencePlateID: "vfx-checker",
            environmentResource: .init(kind: .procedural, fileName: nil, absolutePath: nil, inputTransformID: nil),
            referenceResource: .init(kind: .none, fileName: nil, absolutePath: nil, inputTransformID: nil, alphaMode: nil, signalColorModel: nil, signalMatrix: nil, signalRange: nil, placementID: nil, corners: [])
        ),
        environmentCalibration: nil
    )
}

private func scalarControl(
    _ id: String,
    in presentation: TestPagePresentation?
) -> Double? {
    let controls = (presentation?.previewControls ?? []) + (presentation?.phases ?? []).flatMap {
        $0.sections.flatMap(\.controls)
    }
    guard let descriptor = controls.first(where: { $0.id == id }),
          case let .scalar(control) = descriptor else { return nil }
    return control.value
}

private func sceneCapture() throws -> SavedSceneCapture {
    .init(
        snapshot: .init(
            source: .init(
                kind: .syntheticPattern, patternRawValue: SyntheticPattern.eyeChart.rawValue,
                assets: [], missingMedia: nil
            ),
            currentFrame: 0, viewerZoom: 1, viewerPanX: 0, viewerPanY: 0,
            viewerIsFitted: true, authoring: try sceneAuthoring()
        ),
        thumbnailPNG: Data([1, 2, 3]), generatedEnvironmentEXR: nil
    )
}

@MainActor
@Test func sceneTreeMovementAllocatesMonotonicOrdinalsAndSortsByName() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-scene-tree-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let controller = SceneLibraryController(store: try SceneLibraryStore(directoryURL: root))
    let zeta = try controller.add(capture: sceneCapture(), name: "Zeta")
    let alpha = try controller.add(capture: sceneCapture(), name: "Alpha")
    let production = try controller.createProduction(name: "Producción", seasonSlug: "S01")
    let episode = try controller.createEpisode(in: production.id, name: "Episodio")
    let shot = try controller.createShot(in: episode.id, name: "Plano")

    try controller.moveScene(zeta.id, to: shot.id)
    try controller.moveScene(alpha.id, to: shot.id)
    try controller.moveScene(alpha.id, to: shot.id)
    var stored = try #require(controller.document.productions.first?.episodes.first?.shots.first)
    #expect(stored.scenes.map(\.ordinal) == [1, 2])
    #expect(controller.sortedScenes(stored.scenes.map(\.sceneID)).map(\.name) == ["Plano_001", "Plano_002"])
    #expect(throws: SceneLibraryError.self) {
        try controller.rename(zeta, to: "No permitido")
    }

    try controller.moveScene(zeta.id, to: nil)
    let freeScene = try #require(controller.scene(id: zeta.id))
    try controller.rename(freeScene, to: "Libre")
    try controller.moveScene(zeta.id, to: shot.id)
    try controller.renameShot(shot.id, to: "Plano B")
    stored = try #require(controller.document.productions.first?.episodes.first?.shots.first)
    #expect(stored.scenes.first(where: { $0.sceneID == zeta.id })?.ordinal == 3)
    #expect(stored.nextSceneOrdinal == 4)
    #expect(controller.scene(id: alpha.id)?.name == "Plano B_002")
    #expect(controller.scene(id: zeta.id)?.name == "Plano B_003")
    #expect(try SceneLibraryStore(directoryURL: root).load() == controller.document)
}

@MainActor
@Test func creatingSceneInsideShotIsOnePersistedDerivedPlacement() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-direct-shot-scene-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SceneLibraryStore(directoryURL: root)
    let controller = SceneLibraryController(store: store)
    let production = try controller.createProduction(name: "Producción")
    let episode = try controller.createEpisode(in: production.id, name: "Episodio")
    let shot = try controller.createShot(in: episode.id, name: "PLANO_010")

    let created = try controller.add(capture: sceneCapture(), toShotID: shot.id)
    let stored = try store.load()
    let storedShot = try #require(stored.productions.first?.episodes.first?.shots.first)
    #expect(created.name == "PLANO_010_001")
    #expect(stored.unclassifiedSceneIDs.isEmpty)
    #expect(storedShot.scenes == [.init(sceneID: created.id, ordinal: 1)])
    #expect(storedShot.nextSceneOrdinal == 2)
}

@MainActor
@Test func associatedRenderUsesPersistedValuesWithoutReadingProductionJSON() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-shot-manager-offline-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let libraryRoot = root.appendingPathComponent("library")
    let productionRoot = root.appendingPathComponent("production")
    try FileManager.default.createDirectory(at: productionRoot, withIntermediateDirectories: true)
    let productionID = UUID().uuidString
    let episodeID = UUID().uuidString
    let shotID = UUID().uuidString
    let projection = ShotManagerProductionProjection(
        productionId: productionID, productionSlug: "PROD", seasonSlug: "S01",
        episodes: [.init(id: episodeID, order: 7, slug: "EP07")],
        workstreams: [.init(name: "CG", folders: [.init(name: "renders", suffix: "_beauty")])],
        shots: [.init(id: shotID, episodeId: episodeID, canonicalName: "SH010")]
    )
    let association = ShotManagerProductionAssociation(
        productionId: productionID, productionRootPath: productionRoot.path,
        productionSlug: "PROD", seasonSlug: "S01",
        destinations: [
            .init(
                role: "render", workstreamName: "CG", folderName: "renders",
                folderSuffix: "_beauty"
            ),
            .init(
                role: "comps", workstreamName: "CG", folderName: "comps",
                folderSuffix: "_comp"
            ),
        ]
    )
    let controller = SceneLibraryController(store: try SceneLibraryStore(directoryURL: libraryRoot))
    let scene = try controller.add(capture: sceneCapture(), name: "Prueba")
    let production = try controller.createAssociatedProduction(
        name: "PROD", association: association, projection: projection
    )
    let episode = try controller.createEpisode(in: production.id, name: "EP")
    try controller.associateEpisode(episode.id, with: projection.episodes[0])
    #expect(controller.document.productions[0].episodes[0].name == "EP07")
    #expect(throws: SceneLibraryError.self) {
        try controller.renameEpisode(episode.id, to: "No permitido")
    }
    let shot = try controller.createShot(in: episode.id, name: "SH")
    try controller.moveScene(scene.id, to: shot.id)
    #expect(controller.scene(id: scene.id)?.name == "SH_001")
    try controller.associateShot(shot.id, with: projection.shots[0])
    #expect(controller.document.productions[0].episodes[0].shots[0].name == "SH010")
    #expect(controller.scene(id: scene.id)?.name == "SH010_001")
    #expect(throws: SceneLibraryError.self) {
        try controller.renameShot(shot.id, to: "No permitido")
    }

    let target = try #require(try controller.associatedRenderTarget(for: scene.id))
    #expect(target.outputBaseName == "SH010_beauty_001")
    #expect(target.directoryPath.hasSuffix("/007/CG/renders"))
    #expect(FileManager.default.fileExists(atPath: target.directoryPath))
    #expect(!FileManager.default.fileExists(atPath: productionRoot.appendingPathComponent("production.json").path))

    try controller.makeShotFree(shot.id)
    try controller.renameShot(shot.id, to: "Manual")
    #expect(controller.scene(id: scene.id)?.name == "Manual_001")
}

@Test func productionAssociationPersistsRenderAndCompsDestinationsTogether() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-shot-manager-destinations-\(UUID().uuidString)")
    let productionID = UUID().uuidString
    let read = ShotManagerDocumentRead(
        documentURL: root.appendingPathComponent("production.json"), rootURL: root,
        projection: .init(
            productionId: productionID, productionSlug: "PROD", seasonSlug: "S01",
            episodes: [],
            workstreams: [
                .init(name: "CG", folders: [
                    .init(name: "renders", suffix: "_beauty"),
                    .init(name: "comps", suffix: "_comp"),
                ]),
            ],
            shots: []
        )
    )
    let options = ShotManagerAssociationService.destinationOptions(in: read.projection)
    let association = try ShotManagerAssociationService.makeAssociation(
        from: read, selections: [("render", options[0]), ("comps", options[1])]
    )

    #expect(association.destinations.map(\.role) == ["render", "comps"])
}

@MainActor
@Test func treeInspectorEditsAndDeletesOnlyEmptyBranches() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-tree-inspector-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let controller = SceneLibraryController(store: try SceneLibraryStore(directoryURL: root))
    let production = try controller.createProduction(name: "Producción", seasonSlug: "S01")
    let episode = try controller.createEpisode(in: production.id, name: "Episodio")
    let shot = try controller.createShot(in: episode.id, name: "Plano")

    try controller.renameProduction(production.id, to: "  Proyecto  ")
    try controller.setProductionSeason(production.id, to: "  S02  ")
    try controller.renameEpisode(episode.id, to: "  EP  " )
    try controller.renameShot(shot.id, to: "  SH010  ")
    #expect(controller.document.productions[0].name == "Proyecto")
    #expect(controller.document.productions[0].seasonSlug == "S02")
    #expect(controller.document.productions[0].episodes[0].name == "EP")
    #expect(controller.document.productions[0].episodes[0].shots[0].name == "SH010")
    #expect(throws: SceneLibraryError.self) { try controller.deleteEpisode(episode.id) }
    #expect(throws: SceneLibraryError.self) { try controller.deleteProduction(production.id) }

    try controller.deleteShot(shot.id)
    try controller.deleteEpisode(episode.id)
    try controller.deleteProduction(production.id)
    #expect(controller.document.productions.isEmpty)
}

@Test func sceneLibraryPersistsOnlyTheCurrentStrictContract() throws {
    #expect(SceneLibraryDocument.currentSchemaVersion == 24)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-scenes-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SceneLibraryStore(directoryURL: root)
    #expect(store.documentURL.lastPathComponent == "Scenes.v24.json")
    let id = UUID()
    let snapshot = SavedSceneSnapshot(
        source: .init(
            kind: .syntheticPattern,
            patternRawValue: SyntheticPattern.eyeChart.rawValue,
            assets: [],
            missingMedia: nil
        ),
        currentFrame: 3,
        viewerZoom: 1.25,
        viewerPanX: 12,
        viewerPanY: -8,
        viewerIsFitted: false,
        authoring: try sceneAuthoring()
    )
    let scene = SavedScene(
        id: id,
        name: "Plano referencia",
        thumbnailFileName: "\(id.uuidString.lowercased()).png",
        snapshot: snapshot
    )
    let document = SceneLibraryDocument(scenes: [scene])
    try store.writeThumbnail(Data([1, 2, 3]), for: scene)
    try store.save(document)

    #expect(try store.load() == document)
}

@MainActor
@Test func sceneRenameIsTrimmedAndPersistsAcrossControllerReload() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-scene-rename-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SceneLibraryStore(directoryURL: root)
    let controller = SceneLibraryController(store: store)
    let scene = try controller.add(
        capture: .init(
            snapshot: .init(
                source: .init(
                    kind: .syntheticPattern,
                    patternRawValue: SyntheticPattern.eyeChart.rawValue,
                    assets: [], missingMedia: nil
                ),
                currentFrame: 0, viewerZoom: 1, viewerPanX: 0, viewerPanY: 0,
                viewerIsFitted: true, authoring: try sceneAuthoring()
            ),
            thumbnailPNG: Data([1, 2, 3]), generatedEnvironmentEXR: nil
        ),
        name: "Nombre anterior"
    )

    try controller.rename(scene, to: "  Nombre confirmado  ")
    #expect(controller.scene(id: scene.id)?.name == "Nombre confirmado")

    let reopened = SceneLibraryController(
        store: try SceneLibraryStore(directoryURL: root)
    )
    #expect(reopened.scene(id: scene.id)?.name == "Nombre confirmado")
    #expect(throws: SceneLibraryError.self) {
        try reopened.rename(scene, to: "   ")
    }
    #expect(reopened.scene(id: scene.id)?.name == "Nombre confirmado")
}

@MainActor
@Test func duplicatingScenePreservesExplicitThinLensOverride() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-scene-duplicate-lens-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SceneLibraryStore(directoryURL: root)
    let controller = SceneLibraryController(store: store)
    let base = try sceneAuthoring()
    let authoring = SceneAuthoringDocument(
        profiles: base.profiles,
        overrides: base.overrides + [.choice("lens-evaluation-model", "thin-lens")],
        modelOverrides: base.modelOverrides,
        context: base.context,
        environmentCalibration: base.environmentCalibration
    )
    let original = try controller.add(capture: .init(
        snapshot: .init(
            source: .init(
                kind: .syntheticPattern,
                patternRawValue: SyntheticPattern.eyeChart.rawValue,
                assets: [], missingMedia: nil
            ),
            currentFrame: 0, viewerZoom: 1, viewerPanX: 0, viewerPanY: 0,
            viewerIsFitted: true, authoring: authoring
        ),
        thumbnailPNG: Data([1, 2, 3]),
        generatedEnvironmentEXR: nil
    ))

    let duplicate = try controller.duplicate(original)

    #expect(duplicate.snapshot.authoring == original.snapshot.authoring)
    #expect(duplicate.snapshot.authoring.overrides.contains(
        SceneControlOverride.choice("lens-evaluation-model", "thin-lens")
    ))
}

@MainActor
@Test func savedSceneResolvesCurrentProfileDefaultsButKeepsItsExplicitOverrides() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-scene-profile-resolution-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try GlobalLibraryStore(documentURL: root.appendingPathComponent("library.json"))
    var devices = try RustDeviceCatalog.builtIns()
    let covers = try RustCoverGlassCatalog.builtIns()
    let deviceIndex = try #require(devices.firstIndex {
        $0.maximumWhiteLuminance > $0.minimumWhiteLuminance
    })
    let selectedDevice = devices[deviceIndex]
    let original = try sceneAuthoring()
    let base = SceneAuthoringDocument(
        profiles: .init(
            deviceID: selectedDevice.id,
            coverGlassID: selectedDevice.defaultCoverGlassPresetID,
            captureID: original.profiles.captureID,
            lensID: original.profiles.lensID,
            environmentID: original.profiles.environmentID,
            deliveryID: original.profiles.deliveryID,
            recordingID: original.profiles.recordingID
        ),
        overrides: [], modelOverrides: original.modelOverrides,
        context: original.context, environmentCalibration: nil
    )
    let range = selectedDevice.maximumWhiteLuminance - selectedDevice.minimumWhiteLuminance
    let firstDefault = selectedDevice.minimumWhiteLuminance + range * 0.25
    devices[deviceIndex].whiteLevelNits = firstDefault
    var cameras = try CameraProfileDefinition.builtIns()
    var lenses = try LensProfileDefinition.builtIns()
    var environments = try EnvironmentProfileDefinition.builtIns()
    let cameraIndex = try #require(cameras.firstIndex { $0.id == base.profiles.captureID })
    let lensIndex = try #require(lenses.firstIndex { $0.id == base.profiles.lensID })
    let environmentIndex = try #require(environments.firstIndex {
        $0.id == base.profiles.environmentID
    })
    cameras[cameraIndex].gateWidthMillimeters = 31.2
    lenses[lensIndex].nominalFocalLengthMillimeters = 73
    environments[environmentIndex].environment.ambientRadianceACEScg = [12, 13, 14]
    try store.save(.init(
        devices: devices, coverGlasses: covers,
        cameras: cameras, lenses: lenses, environments: environments
    ))

    func scene(_ authoring: SceneAuthoringDocument) -> SavedScene {
        let id = UUID()
        return .init(
            id: id,
            name: "Perfil actual",
            thumbnailFileName: "\(id.uuidString.lowercased()).png",
            snapshot: .init(
                source: .init(
                    kind: .syntheticPattern,
                    patternRawValue: SyntheticPattern.eyeChart.rawValue,
                    assets: [], missingMedia: nil
                ),
                currentFrame: 0, viewerZoom: 1, viewerPanX: 0, viewerPanY: 0,
                viewerIsFitted: true, authoring: authoring
            )
        )
    }

    let inheritedWorkspace = WorkspaceModel(globalLibraryStore: store)
    await inheritedWorkspace.openSavedScene(scene(base), undoManager: nil)
    #expect(scalarControl("white-luminance", in: inheritedWorkspace.testPresentation)
        == firstDefault)
    #expect(inheritedWorkspace.selectedCapturePresetID == base.profiles.captureID)
    #expect(inheritedWorkspace.selectedLensPresetID == base.profiles.lensID)
    #expect(inheritedWorkspace.physicalAuthoringState?.sceneLens.sensorWidthMillimeters == 31.2)
    #expect(inheritedWorkspace.physicalAuthoringState?.sceneLens.focalLengthMillimeters == 73)
    #expect(inheritedWorkspace.physicalAuthoringState?.environment.ambientRadianceACEScg
        == [12, 13, 14])
    #expect(try inheritedWorkspace.captureSavedScene().snapshot.authoring.overrides
        .contains(where: { $0.controlID == "white-luminance" }) == false)
    let undoManager = UndoManager()
    inheritedWorkspace.handleTestIntent(
        .setScalar(controlID: "white-luminance", value: firstDefault),
        undoManager: undoManager
    )
    #expect(try inheritedWorkspace.captureSavedScene().snapshot.authoring.overrides
        .contains(.scalar("white-luminance", firstDefault)))
    undoManager.undo()
    #expect(try inheritedWorkspace.captureSavedScene().snapshot.authoring.overrides
        .contains(where: { $0.controlID == "white-luminance" }) == false)
    undoManager.redo()
    #expect(try inheritedWorkspace.captureSavedScene().snapshot.authoring.overrides
        .contains(.scalar("white-luminance", firstDefault)))
    inheritedWorkspace.handleTestIntent(
        .reset(controlID: "white-luminance"), undoManager: nil
    )
    #expect(try inheritedWorkspace.captureSavedScene().snapshot.authoring.overrides
        .contains(where: { $0.controlID == "white-luminance" }) == false)

    let authoredValue = selectedDevice.minimumWhiteLuminance + range * 0.5
    let overridden = SceneAuthoringDocument(
        profiles: base.profiles,
        overrides: [.scalar("white-luminance", authoredValue)],
        modelOverrides: base.modelOverrides,
        context: base.context,
        environmentCalibration: base.environmentCalibration
    )
    devices[deviceIndex].whiteLevelNits = selectedDevice.minimumWhiteLuminance + range * 0.75
    cameras[cameraIndex].gateWidthMillimeters = 30.4
    lenses[lensIndex].nominalFocalLengthMillimeters = 81
    environments[environmentIndex].environment.ambientRadianceACEScg = [20, 21, 22]
    try store.save(.init(
        devices: devices, coverGlasses: covers,
        cameras: cameras, lenses: lenses, environments: environments
    ))
    let overriddenWorkspace = WorkspaceModel(globalLibraryStore: store)
    await overriddenWorkspace.openSavedScene(scene(overridden), undoManager: nil)
    #expect(scalarControl("white-luminance", in: overriddenWorkspace.testPresentation)
        == authoredValue)
    #expect(overriddenWorkspace.physicalAuthoringState?.sceneLens.sensorWidthMillimeters == 30.4)
    #expect(overriddenWorkspace.physicalAuthoringState?.sceneLens.focalLengthMillimeters == 81)
    #expect(overriddenWorkspace.physicalAuthoringState?.environment.ambientRadianceACEScg
        == [20, 21, 22])
    #expect(try overriddenWorkspace.captureSavedScene().snapshot.authoring.overrides
        .contains(.scalar("white-luminance", authoredValue)))
    overriddenWorkspace.handleTestIntent(.reset(controlID: "white-luminance"))
    #expect(scalarControl("white-luminance", in: overriddenWorkspace.testPresentation)
        == devices[deviceIndex].whiteLevelNits)
    #expect(try overriddenWorkspace.captureSavedScene().snapshot.authoring.overrides
        .contains(where: { $0.controlID == "white-luminance" }) == false)
}

@MainActor
@Test func unavailableReferenceOpensSceneWithoutTheReferenceAndWarns() async throws {
    let workspace = WorkspaceModel()
    let baseAuthoring = try sceneAuthoring()

    let invalidReference = FileManager.default.temporaryDirectory
        .appendingPathComponent("unreadable-reference-\(UUID().uuidString).mov")
    try Data("not a movie".utf8).write(to: invalidReference)
    defer { try? FileManager.default.removeItem(at: invalidReference) }

    let context = baseAuthoring.context
    let invalidAuthoring = SceneAuthoringDocument(
        profiles: baseAuthoring.profiles,
        overrides: baseAuthoring.overrides,
        modelOverrides: baseAuthoring.modelOverrides,
        context: .init(
            sourceInputTransformID: context.sourceInputTransformID,
            sourceAlphaMode: context.sourceAlphaMode,
            sourceColorModel: context.sourceColorModel,
            sourceYUVMatrix: context.sourceYUVMatrix,
            sourceSignalRange: context.sourceSignalRange,
            sourcePlacementID: context.sourcePlacementID,
            previewOutputTransformID: context.previewOutputTransformID,
            previewPhaseID: context.previewPhaseID,
            referencePlateID: context.referencePlateID,
            environmentResource: context.environmentResource,
            referenceResource: .init(
                kind: .imageOrVideo,
                fileName: invalidReference.lastPathComponent,
                absolutePath: invalidReference.path,
                inputTransformID: "srgb-encoded-rec709",
                alphaMode: StudioAlphaMode.ignore.rawValue,
                signalColorModel: StudioSignalColorModel.rgb.rawValue,
                signalMatrix: StudioSignalMatrix.bt709.rawValue,
                signalRange: StudioSignalRange.full.rawValue,
                placementID: "fit",
                corners: [
                    .init(x: 0, y: 0), .init(x: 1, y: 0),
                    .init(x: 1, y: 1), .init(x: 0, y: 1),
                ]
            )
        ),
        environmentCalibration: baseAuthoring.environmentCalibration
    )
    let incomingID = UUID()
    let incoming = SavedScene(
        id: incomingID,
        name: "No debe publicarse",
        thumbnailFileName: "\(incomingID.uuidString.lowercased()).png",
        snapshot: .init(
            source: .init(
                kind: .syntheticPattern,
                patternRawValue: SyntheticPattern.animatedCheckerboard.rawValue,
                assets: [], missingMedia: nil
            ),
            currentFrame: 7,
            viewerZoom: 2,
            viewerPanX: 40,
            viewerPanY: -30,
            viewerIsFitted: false,
            authoring: invalidAuthoring
        )
    )

    await workspace.openSavedScene(incoming, undoManager: nil)

    let opened = try workspace.captureSavedScene().snapshot
    #expect(workspace.errorMessage?.contains("Referencia descartada") == true)
    #expect(opened.source.patternRawValue == SyntheticPattern.animatedCheckerboard.rawValue)
    #expect(opened.authoring.context.referenceResource.kind == .none)
    #expect(opened.authoring.context.referenceResource.absolutePath == nil)
    #expect(opened.authoring.profiles == incoming.snapshot.authoring.profiles)
}

@MainActor
@Test func missingExternalResourcesOpenAsCleanNewSceneInputs() async throws {
    let base = try sceneAuthoring()
    let missingRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("missing-scene-resources-\(UUID().uuidString)")
    let sourcePath = missingRoot.appendingPathComponent("source.mov").path
    let referencePath = missingRoot.appendingPathComponent("reference.mov").path
    let environmentPath = missingRoot.appendingPathComponent("environment.exr").path
    let authoring = SceneAuthoringDocument(
        profiles: base.profiles,
        overrides: [.choice("environment-source", "environment-image")],
        modelOverrides: base.modelOverrides,
        context: .init(
            sourceInputTransformID: base.context.sourceInputTransformID,
            sourceAlphaMode: base.context.sourceAlphaMode,
            sourceColorModel: base.context.sourceColorModel,
            sourceYUVMatrix: base.context.sourceYUVMatrix,
            sourceSignalRange: base.context.sourceSignalRange,
            sourcePlacementID: base.context.sourcePlacementID,
            previewOutputTransformID: base.context.previewOutputTransformID,
            previewPhaseID: base.context.previewPhaseID,
            referencePlateID: base.context.referencePlateID,
            environmentResource: .init(
                kind: .image,
                fileName: "environment.exr",
                absolutePath: environmentPath,
                inputTransformID: "acescg-linear"
            ),
            referenceResource: .init(
                kind: .imageOrVideo,
                fileName: "reference.mov",
                absolutePath: referencePath,
                inputTransformID: "srgb-encoded-rec709",
                alphaMode: StudioAlphaMode.ignore.rawValue,
                signalColorModel: StudioSignalColorModel.rgb.rawValue,
                signalMatrix: StudioSignalMatrix.bt709.rawValue,
                signalRange: StudioSignalRange.full.rawValue,
                placementID: "fit",
                corners: [
                    .init(x: 0, y: 0), .init(x: 1, y: 0),
                    .init(x: 1, y: 1), .init(x: 0, y: 1),
                ]
            )
        ),
        environmentCalibration: try .init(
            inputTransformID: "acescg-linear",
            sourceUnitRadianceCandelasPerSquareMeter: 1,
            exposureEV: 0
        )
    )
    let id = UUID()
    let scene = SavedScene(
        id: id,
        name: "Recursos ausentes",
        thumbnailFileName: "\(id.uuidString.lowercased()).png",
        snapshot: .init(
            source: .init(
                kind: .externalMedia,
                patternRawValue: nil,
                assets: [.init(absolutePath: sourcePath)],
                missingMedia: .init(
                    originalName: "source.mov", width: 1920, height: 1080,
                    frameRateNumerator: 24, frameRateDenominator: 1,
                    frameCount: 100, durationNumerator: 100, durationDenominator: 24
                )
            ),
            currentFrame: 12,
            viewerZoom: 1,
            viewerPanX: 0,
            viewerPanY: 0,
            viewerIsFitted: true,
            authoring: authoring
        )
    )
    let workspace = WorkspaceModel()
    workspace.togglePreviewTransformationsLock()
    #expect(!workspace.previewTransformationsLocked)

    await workspace.openSavedScene(scene, undoManager: nil)

    #expect(workspace.previewTransformationsLocked)
    let opened = try workspace.captureSavedScene().snapshot
    #expect(workspace.errorMessage?.contains("Fuente descartada") == true)
    #expect(workspace.errorMessage?.contains("Referencia descartada") == true)
    #expect(workspace.errorMessage?.contains("HDRI descartado") == true)
    #expect(opened.source.kind == .syntheticPattern)
    #expect(opened.source.patternRawValue == SyntheticPattern.animatedCheckerboard.rawValue)
    #expect(opened.source.assets.isEmpty)
    #expect(opened.authoring.context.referenceResource.kind == .none)
    #expect(opened.authoring.context.environmentResource.kind == .procedural)
    #expect(opened.authoring.overrides.contains(where: {
        $0.controlID == "environment-source"
    }) == false)
}

@MainActor
@Test func structurallyInvalidSceneOpenLeavesActiveSceneUnchanged() async throws {
    let workspace = WorkspaceModel()
    let base = try sceneAuthoring()
    func scene(_ authoring: SceneAuthoringDocument, pattern: SyntheticPattern) -> SavedScene {
        let id = UUID()
        return .init(
            id: id,
            name: "Escena \(id)",
            thumbnailFileName: "\(id.uuidString.lowercased()).png",
            snapshot: .init(
                source: .init(
                    kind: .syntheticPattern,
                    patternRawValue: pattern.rawValue,
                    assets: [], missingMedia: nil
                ),
                currentFrame: 0,
                viewerZoom: 1,
                viewerPanX: 0,
                viewerPanY: 0,
                viewerIsFitted: true,
                authoring: authoring
            )
        )
    }
    await workspace.openSavedScene(scene(base, pattern: .eyeChart), undoManager: nil)
    let before = try workspace.captureSavedScene().snapshot
    let invalid = SceneAuthoringDocument(
        profiles: .init(
            deviceID: "missing-device",
            coverGlassID: base.profiles.coverGlassID,
            captureID: base.profiles.captureID,
            lensID: base.profiles.lensID,
            environmentID: base.profiles.environmentID,
            deliveryID: base.profiles.deliveryID,
            recordingID: base.profiles.recordingID
        ),
        overrides: base.overrides,
        modelOverrides: base.modelOverrides,
        context: base.context,
        environmentCalibration: base.environmentCalibration
    )

    await workspace.openSavedScene(
        scene(invalid, pattern: .animatedCheckerboard), undoManager: nil
    )

    #expect(workspace.errorMessage?.contains("missing-device") == true)
    #expect(try workspace.captureSavedScene().snapshot == before)
}

@MainActor
@Test func openingScenePublishesItsInitialResolvedViewerFrame() async throws {
    let workspace = WorkspaceModel()
    let id = UUID()
    let saved = SavedScene(
        id: id,
        name: "Publicación inicial",
        thumbnailFileName: "\(id.uuidString.lowercased()).png",
        snapshot: .init(
            source: .init(
                kind: .syntheticPattern,
                patternRawValue: SyntheticPattern.animatedCheckerboard.rawValue,
                assets: [],
                missingMedia: nil
            ),
            currentFrame: 11,
            viewerZoom: 1,
            viewerPanX: 0,
            viewerPanY: 0,
            viewerIsFitted: true,
            authoring: try sceneAuthoring()
        )
    )

    await workspace.openSavedScene(saved, undoManager: nil)

    #expect(workspace.errorMessage == nil)
    #expect(workspace.metalFrame != nil)
    #expect(workspace.hasPublishedResolvedSceneFrame)
}

@MainActor
@Test func autosaveSurvivesSceneDeletionAndRestoresAsANewScene() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-autosave-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let controller = SceneLibraryController(store: try SceneLibraryStore(directoryURL: root))
    let capture = SavedSceneCapture(
        snapshot: .init(
            source: .init(
                kind: .syntheticPattern, patternRawValue: SyntheticPattern.eyeChart.rawValue,
                assets: [], missingMedia: nil
            ),
            currentFrame: 0, viewerZoom: 1, viewerPanX: 0, viewerPanY: 0,
            viewerIsFitted: true,
            authoring: try sceneAuthoring()
        ),
        thumbnailPNG: Data([1, 2, 3]), generatedEnvironmentEXR: nil
    )
    let scene = try controller.add(capture: capture)
    #expect(try controller.autosaves(for: controller.autosaveHistoryTarget(for: scene)).count == 1)

    try controller.delete(scene)
    let target = try #require(controller.deletedAutosaveHistoryTargets().first {
        $0.sceneID == scene.id
    })
    let revision = try #require(try controller.autosaves(for: target).first)
    let restored = try controller.restoreAutosave(revision)

    #expect(restored.id != scene.id)
    #expect(restored.snapshot == scene.snapshot)
    #expect(controller.document.scenes.contains(where: { $0.id == restored.id }))
}

@Test func sceneLibraryPreservesMissingMediaTimingAndInterpretationContext() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-scenes-missing-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SceneLibraryStore(directoryURL: root)
    let id = UUID()
    let missing = SavedMissingMediaDescriptor(
        originalName: "plate.mov",
        width: 4096,
        height: 2160,
        frameRateNumerator: 24_000,
        frameRateDenominator: 1_001,
        frameCount: 240,
        durationNumerator: 10_010,
        durationDenominator: 1_000
    )
    let snapshot = SavedSceneSnapshot(
        source: .init(
            kind: .externalMedia,
            patternRawValue: nil,
            assets: [.init(absolutePath: "/Volumes/plates/plate.mov")],
            missingMedia: missing
        ),
        currentFrame: 73,
        viewerZoom: 2,
        viewerPanX: -41,
        viewerPanY: 19,
        viewerIsFitted: false,
        authoring: try sceneAuthoring()
    )
    let scene = SavedScene(
        id: id,
        name: "Plano sin media",
        thumbnailFileName: "\(id.uuidString.lowercased()).png",
        snapshot: snapshot
    )
    try store.writeThumbnail(Data([1]), for: scene)
    try store.save(.init(scenes: [scene]))

    let restored = try #require(try store.load().scenes.first)
    #expect(restored.snapshot.source.missingMedia == missing)
    #expect(try restored.snapshot.source.missingMedia?.exactFrameRate.framesPerSecond == 24_000.0 / 1_001.0)
    #expect(restored.snapshot.source.missingMedia?.durationNumerator == 10_010)
    #expect(restored.snapshot.source.missingMedia?.durationDenominator == 1_000)
    #expect(restored.snapshot.currentFrame == 73)
}

@Test func sceneLibraryRejectsOldAndUnknownContractsWithoutMutatingThem() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-scenes-reject-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SceneLibraryStore(directoryURL: root)
    let old = Data("{\"schemaVersion\":0,\"scenes\":[]}".utf8)
    try old.write(to: store.documentURL)
    #expect(throws: SceneLibraryError.self) { try store.load() }
    #expect(try Data(contentsOf: store.documentURL) == old)

    let unknown = Data("{\"schemaVersion\":1,\"scenes\":[],\"fallback\":true}".utf8)
    try unknown.write(to: store.documentURL)
    #expect(throws: SceneLibraryError.self) { try store.load() }
    #expect(try Data(contentsOf: store.documentURL) == unknown)
}

@Test func sceneLibraryRejectsUnknownNestedAuthoringInsteadOfIgnoringIt() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-scenes-nested-reject-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SceneLibraryStore(directoryURL: root)
    let id = UUID()
    let scene = SavedScene(
        id: id, name: "Estricto", thumbnailFileName: "\(id.uuidString.lowercased()).png",
        snapshot: .init(
            source: .init(
                kind: .syntheticPattern,
                patternRawValue: SyntheticPattern.eyeChart.rawValue,
                assets: [], missingMedia: nil
            ),
            currentFrame: 0, viewerZoom: 1, viewerPanX: 0, viewerPanY: 0,
            viewerIsFitted: true, authoring: try sceneAuthoring()
        )
    )
    var rootObject = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(
            SceneLibraryDocument(scenes: [scene])
        )) as? [String: Any]
    )
    var scenes = try #require(rootObject["scenes"] as? [[String: Any]])
    var snapshot = try #require(scenes[0]["snapshot"] as? [String: Any])
    var authoring = try #require(snapshot["authoring"] as? [String: Any])
    authoring["selection"] = ["legacyDenseSnapshot": true]
    snapshot["authoring"] = authoring
    scenes[0]["snapshot"] = snapshot
    rootObject["scenes"] = scenes
    let bytes = try JSONSerialization.data(withJSONObject: rootObject)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try bytes.write(to: store.documentURL)

    #expect(throws: SceneLibraryError.self) { try store.load() }
    #expect(try Data(contentsOf: store.documentURL) == bytes)
}

@Test func sceneLibraryOwnsImported3DAuthoringAfterTheImporterFileDisappears() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-scenes-tracking-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("solve.comp")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("temporary importer input".utf8).write(to: source)
    let store = try SceneLibraryStore(
        directoryURL: root.appendingPathComponent("scenes")
    )
    let id = UUID()
    let authoredScene = TrackingScene(
        cameras: [.init(
            id: "/Camera01", label: "Camera01",
            frameRateNumerator: 24, frameRateDenominator: 1,
            focalLengthMillimeters: 35,
            gateWidthMillimeters: 36, gateHeightMillimeters: 20.25,
            plateWidth: 1920, plateHeight: 1080,
            distortion: .pinhole,
            samples: [
                .init(
                    frame: 0, sourcePosition: .init(0, 0, 1),
                    orientation: .init(0, 0, 0, 1)
                ),
                .init(
                    frame: 1, sourcePosition: .init(0.1, 0, 1),
                    orientation: .init(0, 0, 0, 1)
                ),
            ]
        )],
        pointGroups: [.init(
            id: "/Camera01Trackers", label: "Camera01Trackers",
            points: [.init(id: "point-1", label: "Point 1", sourcePosition: .zero)]
        )],
        meshes: [.init(
            id: "/Plane01", label: "Plane01",
            sourceVertices: [
                .init(-1, -1, 0), .init(1, -1, 0),
                .init(1, 1, 0), .init(-1, 1, 0),
            ],
            faceVertexCounts: [4], faceVertexIndices: [0, 1, 2, 3]
        )]
    )
    let tracking = SavedTrackingScene(
        scene: authoredScene,
        cameraID: "/Camera01", pointGroupID: "/Camera01Trackers",
        visibleMeshIDs: ["/Plane01"], pointsVisible: true,
        geometryVisible: false, cameraEnabled: true,
        calibration: .init(
            unitValue: 1,
            unit: "m",
            metersPerSourceUnit: 0.01
        )
    )
    let snapshot = SavedSceneSnapshot(
        source: .init(
            kind: .syntheticPattern,
            patternRawValue: SyntheticPattern.eyeChart.rawValue,
            assets: [], missingMedia: nil
        ),
        currentFrame: 0, viewerZoom: 1, viewerPanX: 0, viewerPanY: 0,
        viewerIsFitted: true,
        authoring: try sceneAuthoring(),
        tracking: tracking
    )
    let scene = SavedScene(
        id: id, name: "Plano con solve",
        thumbnailFileName: "\(id.uuidString.lowercased()).png",
        snapshot: snapshot
    )
    try store.writeThumbnail(Data([1]), for: scene)
    try store.save(.init(scenes: [scene]))
    try FileManager.default.removeItem(at: source)

    let restored = try #require(try store.load().scenes.first)
    #expect(restored.snapshot.tracking == tracking)
    #expect(restored.snapshot.tracking?.scene.cameras.first?.samples.count == 2)
}

@MainActor
@Test func removingImported3DTargetsOneStoredSceneAndIsOneUndoableShelfMutation() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-scene-remove-tracking-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SceneLibraryStore(directoryURL: root)
    let controller = SceneLibraryController(store: store)
    let trackingScene = TrackingScene(
        cameras: [.init(
            id: "/Camera01", label: "Camera01",
            frameRateNumerator: 24, frameRateDenominator: 1,
            focalLengthMillimeters: 35,
            gateWidthMillimeters: 36, gateHeightMillimeters: 20.25,
            plateWidth: 1920, plateHeight: 1080,
            distortion: .pinhole,
            samples: [.init(
                frame: 7, sourcePosition: .init(1, 2, 3),
                orientation: .init(0, 0, 0, 1)
            )]
        )],
        pointGroups: [.init(
            id: "/Trackers", label: "Trackers",
            points: [.init(id: "point-1", label: "Point 1", sourcePosition: .zero)]
        )],
        meshes: []
    )
    let tracking = SavedTrackingScene(
        scene: trackingScene, cameraID: "/Camera01", pointGroupID: "/Trackers",
        visibleMeshIDs: [], pointsVisible: true, geometryVisible: false,
        cameraEnabled: true,
        calibration: .init(unitValue: 1, unit: "m", metersPerSourceUnit: 0.01)
    )
    let snapshot = SavedSceneSnapshot(
        source: .init(
            kind: .syntheticPattern,
            patternRawValue: SyntheticPattern.eyeChart.rawValue,
            assets: [], missingMedia: nil
        ),
        currentFrame: 7, viewerZoom: 1.75, viewerPanX: 12, viewerPanY: -4,
        viewerIsFitted: false, authoring: try sceneAuthoring(), tracking: tracking
    )
    let scene = try controller.add(capture: .init(
        snapshot: snapshot, thumbnailPNG: Data([4, 5, 6]),
        generatedEnvironmentEXR: nil
    ))
    let undo = UndoManager()

    let updated = try controller.removeImported3D(
        scene, destination: .storedScene, undoManager: undo
    )

    #expect(updated.snapshot == snapshot.removingImported3D())
    #expect(updated.id == scene.id)
    #expect(updated.name == scene.name)
    #expect(undo.canUndo)
    undo.undo()
    #expect(controller.scene(id: scene.id)?.snapshot == snapshot)
    #expect(undo.canRedo)
    undo.redo()
    #expect(controller.scene(id: scene.id)?.snapshot == snapshot.removingImported3D())

    let activeSnapshot = SavedSceneSnapshot(
        source: snapshot.source,
        currentFrame: 41,
        viewerZoom: snapshot.viewerZoom,
        viewerPanX: snapshot.viewerPanX,
        viewerPanY: snapshot.viewerPanY,
        viewerIsFitted: snapshot.viewerIsFitted,
        authoring: snapshot.authoring,
        tracking: tracking
    )
    let activeUpdated = try controller.removeImported3D(
        scene,
        destination: .activeScene(.init(
            snapshot: activeSnapshot,
            thumbnailPNG: Data([7, 8, 9]),
            generatedEnvironmentEXR: nil
        ))
    )
    #expect(activeUpdated.snapshot == activeSnapshot.removingImported3D())
    #expect(try Data(contentsOf: store.thumbnailURL(for: activeUpdated)) == Data([7, 8, 9]))
}

@Test func sourceAssetsPreserveTheirAuthoredAbsolutePath() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-scene-source-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("plate.png")
    try Data([9, 8, 7, 6]).write(to: source)
    let managed = try SourceAssetLibrary.importAsset(from: source)
    #expect(managed.url == source)
    #expect(managed.originalFileName == "plate.png")
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("managed").path))
}

@MainActor
@Test func generatedEnvironmentIsOwnedOverwrittenAndDuplicatedWithItsScene() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-scene-environment-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let environmentRoot = root.appendingPathComponent("assets")
    let store = try SceneLibraryStore(
        directoryURL: root.appendingPathComponent("scenes"),
        environmentLibraryRoot: environmentRoot
    )
    let controller = SceneLibraryController(store: store)
    let snapshot = SavedSceneSnapshot(
        source: .init(
            kind: .syntheticPattern,
            patternRawValue: SyntheticPattern.eyeChart.rawValue,
            assets: [], missingMedia: nil
        ),
        currentFrame: 0, viewerZoom: 1, viewerPanX: 0, viewerPanY: 0,
        viewerIsFitted: true, authoring: try sceneAuthoring()
    )
    let originalData = Data([1, 2, 3, 4])
    let scene = try controller.add(capture: .init(
        snapshot: snapshot, thumbnailPNG: Data([9]),
        generatedEnvironmentEXR: originalData
    ))
    let originalAsset = try #require(scene.snapshot.generatedEnvironment)
    let originalManaged = try EnvironmentAssetLibrary.asset(
        sha256: originalAsset.sha256, originalFileName: originalAsset.fileName,
        libraryRoot: environmentRoot
    )
    let originalURL = try #require(originalManaged).url

    let replacement = Data([5, 6, 7, 8])
    let replaced = try controller.replaceGeneratedEnvironment(
        sceneID: scene.id, data: replacement
    )
    #expect(replaced.url == originalURL)
    #expect(try Data(contentsOf: originalURL) == replacement)

    let current = try #require(controller.document.scenes.first { $0.id == scene.id })
    let duplicate = try controller.duplicate(current)
    let duplicateAsset = try #require(duplicate.snapshot.generatedEnvironment)
    #expect(duplicateAsset.fileName != replaced.originalFileName)
    #expect(duplicateAsset.sha256 == replaced.sha256)
    let duplicateManaged = try EnvironmentAssetLibrary.asset(
        sha256: duplicateAsset.sha256, originalFileName: duplicateAsset.fileName,
        libraryRoot: environmentRoot
    )
    let duplicateURL = try #require(duplicateManaged).url
    #expect(duplicateURL != originalURL)
    #expect(try Data(contentsOf: duplicateURL) == replacement)

    try controller.delete(current)
    #expect(!FileManager.default.fileExists(atPath: originalURL.path))
    #expect(FileManager.default.fileExists(atPath: duplicateURL.path))
}

@MainActor
@Test func updatingASceneParticipatesInUndoAndRedoAsOneCompleteOperation() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-scene-update-undo-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let environmentRoot = root.appendingPathComponent("assets")
    let store = try SceneLibraryStore(
        directoryURL: root.appendingPathComponent("scenes"),
        environmentLibraryRoot: environmentRoot
    )
    let controller = SceneLibraryController(store: store)
    func snapshot(frame: Int) throws -> SavedSceneSnapshot {
        SavedSceneSnapshot(
            source: .init(
                kind: .syntheticPattern,
                patternRawValue: SyntheticPattern.eyeChart.rawValue,
                assets: [], missingMedia: nil
            ),
            currentFrame: frame,
            viewerZoom: 1, viewerPanX: 0, viewerPanY: 0,
            viewerIsFitted: true,
            authoring: try sceneAuthoring()
        )
    }
    let originalEnvironment = Data([1, 2, 3, 4])
    let scene = try controller.add(capture: .init(
        snapshot: try snapshot(frame: 3),
        thumbnailPNG: Data([10]),
        generatedEnvironmentEXR: originalEnvironment
    ))
    let undo = UndoManager()
    let updatedEnvironment = Data([5, 6, 7, 8])
    try controller.update(
        scene,
        capture: .init(
            snapshot: try snapshot(frame: 27),
            thumbnailPNG: Data([20]),
            generatedEnvironmentEXR: updatedEnvironment
        ),
        undoManager: undo
    )

    func currentState() throws -> (SavedScene, Data, Data) {
        let current = try #require(controller.scene(id: scene.id))
        let thumbnail = try Data(contentsOf: store.thumbnailURL(for: current))
        let asset = try #require(current.snapshot.generatedEnvironment)
        let managed = try #require(try EnvironmentAssetLibrary.asset(
            sha256: asset.sha256,
            originalFileName: asset.fileName,
            libraryRoot: environmentRoot
        ))
        return (current, thumbnail, try Data(contentsOf: managed.url))
    }

    var state = try currentState()
    #expect(state.0.snapshot.currentFrame == 27)
    #expect(state.1 == Data([20]))
    #expect(state.2 == updatedEnvironment)
    #expect(undo.canUndo)
    undo.undo()
    state = try currentState()
    #expect(state.0.snapshot.currentFrame == 3)
    #expect(state.1 == Data([10]))
    #expect(state.2 == originalEnvironment)
    #expect(undo.canRedo)
    undo.redo()
    state = try currentState()
    #expect(state.0.snapshot.currentFrame == 27)
    #expect(state.1 == Data([20]))
    #expect(state.2 == updatedEnvironment)
}
