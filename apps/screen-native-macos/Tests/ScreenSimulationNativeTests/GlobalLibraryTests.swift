import Foundation
import StudioMedia
import Testing
@testable import ScreenSimulationNative

@Test func globalLibraryPersistsOnlyUserEntitiesInCurrentSchema() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-global-library-\(UUID().uuidString)")
    let url = root.appendingPathComponent("library.json")
    let store = try GlobalLibraryStore(documentURL: url)
    var preset = StudioRenderPreset.builtIns[0]
    preset.id = UUID()
    preset.name = "Usuario"
    let image = GlobalTestImage(
        id: UUID(), name: "Carta HDR", bookmark: Data([1, 2, 3]),
        inputTransformID: "acescg", alpha: .straight,
        matrix: .bt709, range: .full
    )
    let document = GlobalLibraryDocument(testImages: [image], renderPresets: [preset])
    try store.save(document)
    let loaded = try store.load()
    #expect(loaded == document)
    #expect(loaded.schemaVersion == GlobalLibraryDocument.currentSchemaVersion)
    #expect(!loaded.renderPresets.contains { StudioRenderPreset.builtIns.map(\.id).contains($0.id) })
}

@Test func incompatibleGlobalLibraryIsBlockedWithoutLegacyParsingOrDeletion() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-global-library-invalid-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("library.json")
    let bytes = Data("{\"schemaVersion\":0,\"testImages\":[],\"renderPresets\":[]}".utf8)
    try bytes.write(to: url)
    let store = try GlobalLibraryStore(documentURL: url)
    #expect(throws: GlobalLibraryError.self) { try store.load() }
    #expect(try Data(contentsOf: url) == bytes)
}

@Test func schemaOneMigratesAtomicallyAndSeedsCurrentLibrariesOnce() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-global-library-migration-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("library.json")
    try Data(
        "{\"schemaVersion\":1,\"testImages\":[],\"renderPresets\":[]}".utf8
    ).write(to: url)
    let store = try GlobalLibraryStore(documentURL: url)
    var migrated = try store.load()
    #expect(migrated.schemaVersion == GlobalLibraryDocument.currentSchemaVersion)
    #expect(migrated.devices.count == 9)
    #expect(migrated.renderPresets.count == 7)

    migrated.devices.removeFirst()
    migrated.renderPresets.removeFirst()
    try store.save(migrated)
    let reopened = try store.load()
    #expect(reopened.devices.count == 8)
    #expect(reopened.renderPresets.count == 6)
    #expect(reopened == migrated)
}

@Test func schemaTwoPresetMigrationIsExplicitAndAtomic() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-global-library-v2-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("library.json")
    let current = GlobalLibraryDocument(
        renderPresets: [], devices: try RustDeviceCatalog.builtIns()
    )
    var json = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any]
    )
    json["schemaVersion"] = 2
    let previousBytes = try JSONSerialization.data(withJSONObject: json)
    try previousBytes.write(to: url)
    let migrated = try GlobalLibraryStore(documentURL: url).load()
    #expect(migrated.schemaVersion == GlobalLibraryDocument.currentSchemaVersion)
    #expect(migrated.renderPresets == StudioRenderPreset.builtIns)
    #expect(try Data(contentsOf: url) != previousBytes)
}

@Test func schemaThreeAddsExplicitPixelEncodingAtomically() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-global-library-v3-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("library.json")
    let current = GlobalLibraryDocument(
        renderPresets: [StudioRenderPreset.builtIns[0]], devices: []
    )
    var json = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any]
    )
    json["schemaVersion"] = 3
    var presets = try #require(json["renderPresets"] as? [[String: Any]])
    presets[0].removeValue(forKey: "pixelEncoding")
    json["renderPresets"] = presets
    let previousBytes = try JSONSerialization.data(withJSONObject: json)
    try previousBytes.write(to: url)

    let migrated = try GlobalLibraryStore(documentURL: url).load()
    #expect(migrated.schemaVersion == GlobalLibraryDocument.currentSchemaVersion)
    #expect(migrated.renderPresets.first?.pixelEncoding == .yuv44412)
    #expect(migrated.renderPresets.first?.signalRange == .video)
    #expect(try Data(contentsOf: url) != previousBytes)
}

@Test func failedMigrationLeavesTheOriginalEntityUntouched() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-global-library-bad-migration-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("library.json")
    let bytes = Data(
        "{\"schemaVersion\":1,\"testImages\":[],\"renderPresets\":[{}]}".utf8
    )
    try bytes.write(to: url)
    let store = try GlobalLibraryStore(documentURL: url)
    #expect(throws: Error.self) { try store.load() }
    #expect(try Data(contentsOf: url) == bytes)
}

@Test @MainActor func deviceLibraryCRUDPersistsNormalEditableSeedEntries() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-device-crud-\(UUID().uuidString)")
    let store = try GlobalLibraryStore(
        documentURL: root.appendingPathComponent("library.json")
    )
    let controller = GlobalLibraryController(store: store)
    #expect(controller.document.devices.count == 9)
    let originalID = try #require(controller.document.devices.first?.id)
    controller.selectedDeviceID = originalID
    controller.duplicateSelectedDevice()
    let duplicateID = try #require(controller.selectedDeviceID)
    #expect(duplicateID != originalID)
    #expect(controller.document.devices.count == 10)
    controller.updateSelectedDevice { $0.name = "Device usuario" }
    #expect(controller.selectedDevice?.name == "Device usuario")
    controller.removeSelectedDevice()
    #expect(controller.document.devices.count == 9)
    #expect(try store.load().devices.count == 9)
}

@Test @MainActor func seededRenderPresetsAreNormalEditableDeletableEntries() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-render-preset-crud-\(UUID().uuidString)")
    let store = try GlobalLibraryStore(
        documentURL: root.appendingPathComponent("library.json")
    )
    let controller = GlobalLibraryController(store: store)
    #expect(controller.document.renderPresets.count == 7)
    controller.selectedPresetID = controller.document.renderPresets.first?.id
    controller.updateSelectedPreset { $0.name = "ACES SDR personalizado" }
    #expect(controller.allRenderPresets.first?.name == "ACES SDR personalizado")
    controller.removeSelectedPreset()
    #expect(controller.document.renderPresets.count == 6)
    #expect(try store.load().renderPresets.count == 6)
}

@Test @MainActor func invalidDeviceEditIsRejectedWithoutMutatingTheResolvedEntry() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-device-invalid-edit-\(UUID().uuidString)")
    let controller = GlobalLibraryController(
        store: try GlobalLibraryStore(
            documentURL: root.appendingPathComponent("library.json")
        )
    )
    controller.selectedDeviceID = controller.document.devices.first?.id
    let original = try #require(controller.selectedDevice)
    controller.updateSelectedDevice { $0.nativeWidth = 0 }
    #expect(controller.selectedDevice == original)
    #expect(controller.deviceValidationMessage != nil)
}
