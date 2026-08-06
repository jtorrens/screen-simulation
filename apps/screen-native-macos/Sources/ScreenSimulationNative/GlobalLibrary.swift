import AppKit
import Foundation
import StudioColor
import StudioMedia
import UniformTypeIdentifiers

struct GlobalTestImage: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var bookmark: Data
    var inputTransformID: String
    var alpha: StudioAlphaMode
    var matrix: StudioSignalMatrix
    var range: StudioSignalRange

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GlobalLibraryError.invalidEntity("La imagen de prueba necesita nombre.")
        }
        guard StudioColorInputTransform.catalog.contains(where: { $0.id == inputTransformID }) else {
            throw GlobalLibraryError.invalidEntity("La IDT de \(name) no existe en StudioColor.")
        }
        guard !bookmark.isEmpty else {
            throw GlobalLibraryError.invalidEntity("La imagen de prueba \(name) no contiene bookmark.")
        }
    }
}

struct GlobalLibraryDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    var testImages: [GlobalTestImage]
    var renderPresets: [StudioRenderPreset]

    init(testImages: [GlobalTestImage] = [], renderPresets: [StudioRenderPreset] = []) {
        schemaVersion = Self.currentSchemaVersion
        self.testImages = testImages
        self.renderPresets = renderPresets
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw GlobalLibraryError.unsupportedSchema(schemaVersion)
        }
        guard Set(testImages.map(\.id)).count == testImages.count,
              Set(renderPresets.map(\.id)).count == renderPresets.count
        else { throw GlobalLibraryError.invalidEntity("Hay identificadores globales duplicados.") }
        try testImages.forEach { try $0.validate() }
        guard renderPresets.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw GlobalLibraryError.invalidEntity("Todos los presets necesitan nombre.")
        }
    }
}

enum GlobalLibraryError: Error, LocalizedError {
    case unsupportedSchema(Int)
    case invalidEntity(String)
    case inaccessible(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            "La biblioteca global usa el esquema \(version); esta versión exige el esquema 1. La entidad queda bloqueada."
        case let .invalidEntity(message), let .inaccessible(message): message
        }
    }
}

struct GlobalLibraryStore: Sendable {
    let documentURL: URL

    init(documentURL: URL? = nil) throws {
        if let documentURL {
            self.documentURL = documentURL
            return
        }
        let root = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("SCREEN-SIMULATION", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.documentURL = root.appendingPathComponent("GlobalLibrary.v1.json")
    }

    func load() throws -> GlobalLibraryDocument {
        guard FileManager.default.fileExists(atPath: documentURL.path) else {
            return GlobalLibraryDocument()
        }
        let document = try JSONDecoder().decode(
            GlobalLibraryDocument.self,
            from: Data(contentsOf: documentURL)
        )
        try document.validate()
        return document
    }

    func save(_ document: GlobalLibraryDocument) throws {
        try document.validate()
        try FileManager.default.createDirectory(
            at: documentURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: documentURL, options: .atomic)
    }
}

@MainActor
final class GlobalLibraryController: ObservableObject {
    @Published private(set) var document = GlobalLibraryDocument()
    @Published var selectedImageID: UUID?
    @Published var selectedPresetID: UUID?
    @Published private(set) var blockedError: String?

    private let store: GlobalLibraryStore?

    init(store: GlobalLibraryStore? = try? GlobalLibraryStore()) {
        self.store = store
        guard let store else {
            blockedError = "No se puede abrir Application Support para la biblioteca global."
            return
        }
        do {
            document = try store.load()
            selectedImageID = document.testImages.first?.id
            selectedPresetID = allRenderPresets.first?.id
        } catch {
            blockedError = error.localizedDescription
        }
    }

    var allRenderPresets: [StudioRenderPreset] {
        StudioRenderPreset.builtIns + document.renderPresets
    }

    func addTestImage() {
        guard blockedError == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, UTType(filenameExtension: "exr")!]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let entry = GlobalTestImage(
                id: UUID(), name: url.deletingPathExtension().lastPathComponent,
                bookmark: bookmark,
                inputTransformID: url.pathExtension.lowercased() == "exr" ? "acescg" : "display-srgb-aces2-sdr",
                alpha: .straight, matrix: .bt709, range: .full
            )
            document.testImages.append(entry)
            selectedImageID = entry.id
            try persist()
        } catch { blockedError = error.localizedDescription }
    }

    func updateSelectedImage(_ mutation: (inout GlobalTestImage) -> Void) {
        guard let selectedImageID,
              let index = document.testImages.firstIndex(where: { $0.id == selectedImageID })
        else { return }
        mutation(&document.testImages[index])
        persistOrBlock()
    }

    func removeSelectedImage() {
        guard let selectedImageID else { return }
        document.testImages.removeAll { $0.id == selectedImageID }
        self.selectedImageID = document.testImages.first?.id
        persistOrBlock()
    }

    func addRenderPreset() {
        var preset = StudioRenderPreset.builtIns[0]
        preset.id = UUID()
        preset.name = "Preset personalizado"
        document.renderPresets.append(preset)
        selectedPresetID = preset.id
        persistOrBlock()
    }

    func duplicateSelectedPreset() {
        guard let selectedPresetID,
              var preset = allRenderPresets.first(where: { $0.id == selectedPresetID })
        else { return }
        preset.id = UUID()
        preset.name += " copia"
        document.renderPresets.append(preset)
        self.selectedPresetID = preset.id
        persistOrBlock()
    }

    func updateSelectedPreset(_ mutation: (inout StudioRenderPreset) -> Void) {
        guard let selectedPresetID,
              let index = document.renderPresets.firstIndex(where: { $0.id == selectedPresetID })
        else { return }
        mutation(&document.renderPresets[index])
        persistOrBlock()
    }

    func removeSelectedPreset() {
        guard let selectedPresetID else { return }
        document.renderPresets.removeAll { $0.id == selectedPresetID }
        self.selectedPresetID = allRenderPresets.first?.id
        persistOrBlock()
    }

    private func persistOrBlock() {
        do { try persist() } catch { blockedError = error.localizedDescription }
    }

    private func persist() throws {
        guard let store else { throw GlobalLibraryError.inaccessible("La biblioteca global no tiene destino.") }
        try store.save(document)
    }
}
