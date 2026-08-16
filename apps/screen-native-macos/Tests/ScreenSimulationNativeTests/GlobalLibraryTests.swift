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

@Test func schemaSevenIsRejectedWithoutACompatibilityReader() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-global-library-v7-rejected-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("library.json")
    let current = GlobalLibraryDocument(
        devices: try RustDeviceCatalog.builtIns(),
        coverGlasses: try RustCoverGlassCatalog.builtIns()
    )
    var object = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any]
    )
    object["schemaVersion"] = 7
    let bytes = try JSONSerialization.data(withJSONObject: object)
    try bytes.write(to: url)

    #expect(throws: GlobalLibraryError.self) {
        try GlobalLibraryStore(documentURL: url).load()
    }
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
    #expect(migrated.renderPresets.count == 9)

    migrated.devices.removeFirst()
    migrated.renderPresets.removeFirst()
    try store.save(migrated)
    let reopened = try store.load()
    #expect(reopened.devices.count == 8)
    #expect(reopened.renderPresets.count == 8)
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
    json["devices"] = (json["devices"] as? [[String: Any]])?.compactMap {
        $0["value"]
    }
    let previousBytes = try JSONSerialization.data(withJSONObject: json)
    try previousBytes.write(to: url)
    let migrated = try GlobalLibraryStore(documentURL: url).load()
    #expect(migrated.schemaVersion == GlobalLibraryDocument.currentSchemaVersion)
    #expect(migrated.renderPresets.map(\.value) == StudioRenderPreset.builtIns)
    #expect(migrated.renderPresets.allSatisfy { $0.isLocked })
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
        .compactMap { $0["value"] as? [String: Any] }
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

@Test func schemaFourAddsLockedCoverGlassAndMigratesExistingSeedsAtomically() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-global-library-v4-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let url = root.appendingPathComponent("library.json")
    let renderPresets = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(StudioRenderPreset.builtIns)
    )
    let devices = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(try RustDeviceCatalog.builtIns())
    )
    let bytes = try JSONSerialization.data(withJSONObject: [
        "schemaVersion": 4,
        "testImages": [],
        "renderPresets": renderPresets,
        "devices": devices,
    ])
    try bytes.write(to: url)

    let migrated = try GlobalLibraryStore(documentURL: url).load()
    #expect(migrated.schemaVersion == GlobalLibraryDocument.currentSchemaVersion)
    #expect(migrated.renderPresets.allSatisfy { $0.isLocked })
    #expect(migrated.devices.allSatisfy { $0.isLocked })
    #expect(migrated.coverGlasses.count == 6)
    #expect(migrated.coverGlasses.allSatisfy { $0.isLocked })
    #expect(try Data(contentsOf: url) != bytes)
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

@Test @MainActor func deviceSeedCanAlwaysDuplicateAndUnlockIntoANormalItem() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-device-crud-\(UUID().uuidString)")
    let store = try GlobalLibraryStore(
        documentURL: root.appendingPathComponent("library.json")
    )
    let controller = GlobalLibraryController(store: store)
    #expect(controller.document.devices.count == 9)
    let originalID = try #require(controller.document.devices.first?.id)
    controller.selectedDeviceID = originalID
    #expect(controller.selectedDeviceItem?.isLocked == true)
    let originalName = controller.selectedDevice?.name
    controller.updateSelectedDevice { $0.name = "No debe cambiar" }
    #expect(controller.selectedDevice?.name == originalName)
    controller.duplicateSelectedDevice()
    let duplicateID = try #require(controller.selectedDeviceID)
    #expect(duplicateID != originalID)
    #expect(controller.document.devices.count == 10)
    #expect(controller.selectedDeviceItem?.isLocked == false)
    controller.updateSelectedDevice { $0.name = "Device usuario" }
    #expect(controller.selectedDevice?.name == "Device usuario")
    controller.removeSelectedDevice()
    #expect(controller.document.devices.count == 9)
    #expect(try store.load().devices.count == 9)

    controller.selectedDeviceID = originalID
    controller.unlockSelectedDevice()
    #expect(controller.selectedDeviceItem?.isLocked == false)
    controller.updateSelectedDevice { $0.name = "Seed desbloqueado" }
    #expect(controller.selectedDevice?.name == "Seed desbloqueado")
}

@Test @MainActor func renderSeedCanAlwaysDuplicateAndUnlockIntoANormalItem() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-render-preset-crud-\(UUID().uuidString)")
    let store = try GlobalLibraryStore(
        documentURL: root.appendingPathComponent("library.json")
    )
    let controller = GlobalLibraryController(store: store)
    #expect(controller.document.renderPresets.count == 9)
    controller.selectedPresetID = controller.document.renderPresets.first?.id
    let originalName = controller.selectedPresetItem?.name
    #expect(controller.selectedPresetItem?.isLocked == true)
    controller.updateSelectedPreset { $0.name = "No debe cambiar" }
    #expect(controller.selectedPresetItem?.name == originalName)
    controller.duplicateSelectedPreset()
    #expect(controller.document.renderPresets.count == 10)
    #expect(controller.selectedPresetItem?.isLocked == false)
    controller.updateSelectedPreset { $0.name = "ACES SDR personalizado" }
    #expect(controller.selectedPresetItem?.name == "ACES SDR personalizado")
    controller.removeSelectedPreset()
    #expect(controller.document.renderPresets.count == 9)

    controller.selectedPresetID = controller.document.renderPresets.first?.id
    controller.unlockSelectedPreset()
    #expect(controller.selectedPresetItem?.isLocked == false)
    controller.removeSelectedPreset()
    #expect(try store.load().renderPresets.count == 8)
}

@Test @MainActor func currentRenderCatalogSupersedesStoredBuiltInCopies() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-render-catalog-\(UUID().uuidString)")
    let store = try GlobalLibraryStore(
        documentURL: root.appendingPathComponent("library.json")
    )
    var stored = GlobalLibraryDocument()
    stored.renderPresets.removeLast(2)
    try store.save(stored)
    let controller = GlobalLibraryController(store: store)
    #expect(controller.document.renderPresets.count == 7)
    #expect(controller.allRenderPresets == StudioRenderPreset.builtIns)
}

@Test @MainActor func coverGlassSeedsUseTheRustAuthorityAndGenericLockContract() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-cover-glass-crud-\(UUID().uuidString)")
    let store = try GlobalLibraryStore(
        documentURL: root.appendingPathComponent("library.json")
    )
    let controller = GlobalLibraryController(store: store)
    #expect(controller.document.coverGlasses.count == 6)
    #expect(controller.document.coverGlasses.allSatisfy { $0.isLocked })
    #expect(controller.document.coverGlasses.allSatisfy {
        $0.value.agMicrotextureCharacterStrength >= 0
            && $0.value.agMicrotextureCharacterStrength <= 4
            && $0.value.agMicrotextureRMSSlope >= 0
            && $0.value.agMicrotextureCorrelationLengthMicrometers > 0
            && $0.value.agMicrotextureAnisotropy >= 0
            && $0.value.agMicrotextureAnisotropy <= 1
    })
    controller.selectedCoverGlassID = controller.document.coverGlasses.first?.id
    let originalID = try #require(controller.selectedCoverGlassID)
    controller.duplicateSelectedCoverGlass()
    #expect(controller.selectedCoverGlassID != originalID)
    #expect(controller.selectedCoverGlassItem?.isLocked == false)
    controller.updateSelectedCoverGlass { $0.name = "Cristal usuario" }
    #expect(controller.selectedCoverGlass?.name == "Cristal usuario")
    controller.removeSelectedCoverGlass()
    #expect(controller.document.coverGlasses.count == 6)

    controller.selectedCoverGlassID = originalID
    controller.unlockSelectedCoverGlass()
    #expect(controller.selectedCoverGlassItem?.isLocked == false)
    controller.updateSelectedCoverGlass { $0.roughness = 0.1 }
    #expect(controller.selectedCoverGlass?.roughness == 0.1)
}

@Test @MainActor func patternSeedsUseTheSameDuplicateAndUnlockContract() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-pattern-crud-\(UUID().uuidString)")
    let controller = GlobalLibraryController(
        store: try GlobalLibraryStore(
            documentURL: root.appendingPathComponent("library.json")
        )
    )
    #expect(controller.document.patterns.count == 7)
    #expect(controller.document.patterns.allSatisfy { $0.isLocked })
    controller.selectedPatternID = controller.document.patterns.first?.id
    controller.duplicateSelectedPattern()
    #expect(controller.document.patterns.count == 8)
    #expect(controller.selectedPatternItem?.isLocked == false)
    controller.updateSelectedPattern { $0.name = "Patrón usuario" }
    #expect(controller.selectedPatternItem?.name == "Patrón usuario")
    controller.removeSelectedPattern()
    #expect(controller.document.patterns.count == 7)
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
    controller.unlockSelectedDevice()
    let original = try #require(controller.selectedDevice)
    controller.updateSelectedDevice { $0.nativeWidth = 0 }
    #expect(controller.selectedDevice == original)
    #expect(controller.deviceValidationMessage != nil)
}
