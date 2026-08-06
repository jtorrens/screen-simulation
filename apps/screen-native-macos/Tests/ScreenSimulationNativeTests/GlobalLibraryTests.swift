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
