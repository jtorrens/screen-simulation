import Foundation
import Testing
@testable import ScreenSimulationNative

@Test func sceneLibraryPersistsOnlyTheCurrentStrictContract() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-scenes-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SceneLibraryStore(directoryURL: root)
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
            kind: .managedMedia,
            patternRawValue: nil,
            assets: [.init(fileName: "plate.mov", sha256: String(repeating: "a", count: 64))],
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

@Test func sceneLibraryRejectsASelectedRetiredIndexInsteadOfOpeningEmpty() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-scenes-retired-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try SceneLibraryStore(directoryURL: root)
    let retired = root.appendingPathComponent("Scenes.v1.json")
    let bytes = Data("{\"schemaVersion\":1,\"scenes\":[]}".utf8)
    try bytes.write(to: retired)

    #expect(throws: SceneLibraryError.self) { try store.load() }
    #expect(try Data(contentsOf: retired) == bytes)
    #expect(!FileManager.default.fileExists(atPath: store.documentURL.path))
}

@Test func sourceAssetsAreContentAddressedAndResolvedWithoutFilenameInference() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-scene-source-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("plate.png")
    try Data([9, 8, 7, 6]).write(to: source)
    let libraryRoot = root.appendingPathComponent("managed")

    let managed = try SourceAssetLibrary.importAsset(from: source, libraryRoot: libraryRoot)
    let candidate = try SourceAssetLibrary.asset(
        sha256: managed.sha256,
        originalFileName: managed.originalFileName,
        libraryRoot: libraryRoot
    )
    let resolved = try #require(candidate)
    #expect(try Data(contentsOf: resolved.url) == Data([9, 8, 7, 6]))
    #expect(try SourceAssetLibrary.asset(
        sha256: String(repeating: "0", count: 64),
        originalFileName: managed.originalFileName,
        libraryRoot: libraryRoot
    ) == nil)
    try Data([0, 0, 0, 0]).write(to: resolved.url, options: .atomic)
    #expect(try SourceAssetLibrary.asset(
        sha256: managed.sha256,
        originalFileName: managed.originalFileName,
        libraryRoot: libraryRoot
    ) == nil)
}
