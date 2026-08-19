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

@Test @MainActor func everySimulationProfileFamilyUsesTheSameSeedAndUserCRUDContract() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-profile-family-crud-\(UUID().uuidString)")
    let store = try GlobalLibraryStore(
        documentURL: root.appendingPathComponent("library.json")
    )
    let controller = GlobalLibraryController(store: store)

    let cameraCount = controller.document.cameras.count
    let lensCount = controller.document.lenses.count
    let environmentCount = controller.document.environments.count
    #expect(cameraCount > 0 && lensCount > 0 && environmentCount > 0)
    #expect(controller.selectedCameraItem?.isLocked == true)
    #expect(controller.selectedLensItem?.isLocked == true)
    #expect(controller.selectedEnvironmentItem?.isLocked == true)

    controller.addCamera()
    #expect(controller.document.cameras.count == cameraCount + 1)
    #expect(controller.selectedCameraItem?.isLocked == false)
    controller.updateSelectedCamera { $0.name = "Cámara usuario" }
    #expect(controller.selectedCameraItem?.name == "Cámara usuario")

    controller.addLens()
    #expect(controller.document.lenses.count == lensCount + 1)
    #expect(controller.selectedLensItem?.isLocked == false)
    controller.updateSelectedLens { $0.name = "Lente usuario" }
    #expect(controller.selectedLensItem?.name == "Lente usuario")

    controller.addEnvironment()
    #expect(controller.document.environments.count == environmentCount + 1)
    #expect(controller.selectedEnvironmentItem?.isLocked == false)
    controller.updateSelectedEnvironment { $0.name = "Entorno usuario" }
    #expect(controller.selectedEnvironmentItem?.name == "Entorno usuario")

    let persisted = try store.load()
    #expect(persisted.cameras.contains { $0.name == "Cámara usuario" })
    #expect(persisted.lenses.contains { $0.name == "Lente usuario" })
    #expect(persisted.environments.contains { $0.name == "Entorno usuario" })
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

@Test @MainActor func storedRenderProfilesRemainTheOnlyRuntimeAuthority() throws {
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
    #expect(controller.allRenderPresets == stored.renderPresets.map(\.value))
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
