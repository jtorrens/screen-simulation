import Foundation
import Testing
@testable import ScreenSimulationNative

@Test func sceneLibraryPersistsOnlyTheCurrentStrictContract() throws {
    #expect(SceneLibraryDocument.currentSchemaVersion == 17)
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-scenes-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SceneLibraryStore(directoryURL: root)
    #expect(store.documentURL.lastPathComponent == "Scenes.v17.json")
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
        settingsDocument: try JSONSerialization.data(
            withJSONObject: ["settings": ["schema": PhysicalSettingsExchange.schema]]
        )
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
            settingsDocument: try JSONSerialization.data(
                withJSONObject: ["settings": ["schema": PhysicalSettingsExchange.schema]]
            )
        ),
        thumbnailPNG: Data([1, 2, 3]), generatedEnvironmentEXR: nil
    )
    let scene = try controller.add(capture: capture)
    #expect(try controller.autosaves(for: controller.autosaveHistoryTarget(for: scene)).count == 1)

    try controller.delete(scene)
    let target = try #require(controller.deletedAutosaveHistoryTargets().first)
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
        settingsDocument: try JSONSerialization.data(
            withJSONObject: ["settings": ["schema": PhysicalSettingsExchange.schema]]
        )
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

@Test func sceneLibraryPersistsFusionIdentityVisibilityAndMetricCalibration() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-scenes-tracking-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("solve.comp")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("fusion fixture".utf8).write(to: source)
    let managed = try TrackingAssetLibrary.importAsset(from: source)
    let store = try SceneLibraryStore(
        directoryURL: root.appendingPathComponent("scenes")
    )
    let id = UUID()
    let tracking = SavedTrackingScene(
        absolutePath: managed.url.path,
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
        settingsDocument: try JSONSerialization.data(
            withJSONObject: ["settings": ["schema": PhysicalSettingsExchange.schema]]
        ),
        tracking: tracking
    )
    let scene = SavedScene(
        id: id, name: "Plano con solve",
        thumbnailFileName: "\(id.uuidString.lowercased()).png",
        snapshot: snapshot
    )
    try store.writeThumbnail(Data([1]), for: scene)
    try store.save(.init(scenes: [scene]))

    let restored = try #require(try store.load().scenes.first)
    #expect(restored.snapshot.tracking == tracking)
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
    let settings = try JSONSerialization.data(withJSONObject: [
        "settings": [
            "schema": PhysicalSettingsExchange.schema,
            "context": [
                "environmentResource": [
                    "kind": "procedural",
                    "presetID": "environment-none",
                ],
            ],
        ],
    ])
    let snapshot = SavedSceneSnapshot(
        source: .init(
            kind: .syntheticPattern,
            patternRawValue: SyntheticPattern.eyeChart.rawValue,
            assets: [], missingMedia: nil
        ),
        currentFrame: 0, viewerZoom: 1, viewerPanX: 0, viewerPanY: 0,
        viewerIsFitted: true, settingsDocument: settings
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
            settingsDocument: try JSONSerialization.data(
                withJSONObject: ["settings": [
                    "schema": PhysicalSettingsExchange.schema,
                    "context": ["environmentResource": [
                        "kind": "procedural",
                        "presetID": "environment-none",
                    ]],
                ]]
            )
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
