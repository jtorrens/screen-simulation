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
    static let currentSchemaVersion = 4
    let schemaVersion: Int
    var testImages: [GlobalTestImage]
    var renderPresets: [StudioRenderPreset]
    var devices: [DeviceDefinition]

    init(
        testImages: [GlobalTestImage] = [],
        renderPresets: [StudioRenderPreset] = StudioRenderPreset.builtIns,
        devices: [DeviceDefinition] = []
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.testImages = testImages
        self.renderPresets = renderPresets
        self.devices = devices
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw GlobalLibraryError.unsupportedSchema(schemaVersion)
        }
        guard Set(testImages.map(\.id)).count == testImages.count,
              Set(renderPresets.map(\.id)).count == renderPresets.count,
              Set(devices.map(\.id)).count == devices.count
        else { throw GlobalLibraryError.invalidEntity("Hay identificadores globales duplicados.") }
        try testImages.forEach { try $0.validate() }
        try devices.forEach { _ = try $0.resolved() }
        guard renderPresets.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw GlobalLibraryError.invalidEntity("Todos los presets necesitan nombre.")
        }
        guard renderPresets.allSatisfy({ preset in
            preset.format.supportedPixelEncodings.contains(preset.pixelEncoding)
                && preset.format.supportedSignalRanges(for: preset.pixelEncoding)
                    .contains(preset.signalRange)
                && (preset.format.supportsAlpha || preset.alpha == .ignore)
                && (preset.format.isMovie || !preset.includeAudio)
                && ((preset.target == .sdr || preset.target == .hdr)
                    ? preset.display != nil && preset.view != nil
                    : preset.display == nil && preset.view == nil)
        }) else {
            throw GlobalLibraryError.invalidEntity(
                "Un preset combina formato, rango, alpha, audio u ODT incompatibles."
            )
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
            "La biblioteca global usa el esquema \(version); esta versión exige el esquema \(GlobalLibraryDocument.currentSchemaVersion). La entidad queda bloqueada."
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
            let document = GlobalLibraryDocument(
                renderPresets: StudioRenderPreset.builtIns,
                devices: try RustDeviceCatalog.builtIns()
            )
            try document.validate()
            return document
        }
        let data = try Data(contentsOf: documentURL)
        let version = try JSONDecoder().decode(
            GlobalLibrarySchemaHeader.self,
            from: data
        ).schemaVersion
        switch version {
        case GlobalLibraryDocument.currentSchemaVersion:
            let document = try JSONDecoder().decode(
                GlobalLibraryDocument.self,
                from: data
            )
            try document.validate()
            return document
        case 1:
            let previous = try JSONDecoder().decode(
                GlobalLibrarySchemaOne.self,
                from: data
            )
            let migrated = GlobalLibraryDocument(
                testImages: previous.testImages,
                renderPresets: migratedPresets(previous.renderPresets),
                devices: try RustDeviceCatalog.builtIns()
            )
            try migrated.validate()
            try save(migrated)
            return migrated
        case 2:
            let previous = try JSONDecoder().decode(
                GlobalLibrarySchemaTwo.self,
                from: data
            )
            let migrated = GlobalLibraryDocument(
                testImages: previous.testImages,
                renderPresets: migratedPresets(previous.renderPresets),
                devices: previous.devices
            )
            try migrated.validate()
            try save(migrated)
            return migrated
        case 3:
            let previous = try JSONDecoder().decode(
                GlobalLibrarySchemaThree.self,
                from: data
            )
            let migrated = GlobalLibraryDocument(
                testImages: previous.testImages,
                renderPresets: previous.renderPresets.map(\.current),
                devices: previous.devices
            )
            try migrated.validate()
            try save(migrated)
            return migrated
        default:
            throw GlobalLibraryError.unsupportedSchema(version)
        }
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

    private func migratedPresets(
        _ previous: [GlobalRenderPresetSchemaTwo]
    ) -> [StudioRenderPreset] {
        let existingIDs = Set(previous.map(\.id))
        let seeded = StudioRenderPreset.builtIns.filter { !existingIDs.contains($0.id) }
        return seeded + previous.map { $0.current }
    }
}

private struct GlobalLibrarySchemaHeader: Decodable {
    let schemaVersion: Int
}

private struct GlobalLibrarySchemaOne: Decodable {
    let schemaVersion: Int
    let testImages: [GlobalTestImage]
    let renderPresets: [GlobalRenderPresetSchemaTwo]
}

private struct GlobalLibrarySchemaTwo: Decodable {
    let schemaVersion: Int
    let testImages: [GlobalTestImage]
    let renderPresets: [GlobalRenderPresetSchemaTwo]
    let devices: [DeviceDefinition]
}

private struct GlobalLibrarySchemaThree: Decodable {
    let schemaVersion: Int
    let testImages: [GlobalTestImage]
    let renderPresets: [GlobalRenderPresetSchemaThree]
    let devices: [DeviceDefinition]
}

private struct GlobalRenderPresetSchemaTwo: Decodable {
    let id: UUID
    let name: String
    let pipeline: StudioRenderPipeline
    let target: StudioRenderTarget
    let peakNits: Double
    let display: String?
    let view: String?

    var current: StudioRenderPreset {
        if let builtIn = StudioRenderPreset.builtIns.first(where: { $0.id == id }) {
            return builtIn
        }
        let isLinear = target == .acescg || target == .aces2065
        return StudioRenderPreset(
            id: id,
            name: name,
            pipeline: pipeline,
            target: target,
            peakNits: peakNits,
            display: display,
            view: view,
            format: isLinear ? .openEXR : .proRes4444,
            pixelEncoding: isLinear ? .rgba16Float : .yuv44412,
            signalRange: isLinear ? .full : .video,
            alpha: isLinear ? .straight : .premultiplied,
            includeAudio: false,
            notes: ""
        )
    }
}

private struct GlobalRenderPresetSchemaThree: Decodable {
    let id: UUID
    let name: String
    let pipeline: StudioRenderPipeline
    let target: StudioRenderTarget
    let peakNits: Double
    let display: String?
    let view: String?
    let format: StudioOutputFormat
    let signalRange: StudioSignalRange
    let alpha: StudioAlphaMode
    let includeAudio: Bool
    let notes: String

    var current: StudioRenderPreset {
        let encoding = format.defaultPixelEncoding
        let supportedRanges = format.supportedSignalRanges(for: encoding)
        return StudioRenderPreset(
            id: id,
            name: name,
            pipeline: pipeline,
            target: target,
            peakNits: peakNits,
            display: display,
            view: view,
            format: format,
            pixelEncoding: encoding,
            signalRange: supportedRanges.contains(signalRange)
                ? signalRange : supportedRanges[0],
            alpha: alpha,
            includeAudio: includeAudio,
            notes: notes
        )
    }
}

@MainActor
final class GlobalLibraryController: ObservableObject {
    @Published private(set) var document = GlobalLibraryDocument()
    @Published var selectedImageID: UUID?
    @Published var selectedPresetID: UUID?
    @Published var selectedDeviceID: String?
    @Published private(set) var deviceValidationMessage: String?
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
            selectedDeviceID = document.devices.first?.id
        } catch {
            blockedError = error.localizedDescription
        }
    }

    var allRenderPresets: [StudioRenderPreset] {
        document.renderPresets
    }

    var selectedDevice: DeviceDefinition? {
        document.devices.first { $0.id == selectedDeviceID }
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
        var candidate = document
        mutation(&candidate.renderPresets[index])
        do {
            try candidate.validate()
            try persist(candidate)
            document = candidate
            blockedError = nil
        } catch {
            blockedError = error.localizedDescription
        }
    }

    func removeSelectedPreset() {
        guard let selectedPresetID else { return }
        document.renderPresets.removeAll { $0.id == selectedPresetID }
        self.selectedPresetID = document.renderPresets.first?.id
        persistOrBlock()
    }

    func addDevice() {
        guard let catalog = try? RustDeviceCatalog.builtIns(),
              var device = catalog.first
        else { return }
        device.id = UUID().uuidString.lowercased()
        device.name = "Device personalizado"
        document.devices.append(device)
        selectedDeviceID = device.id
        deviceValidationMessage = nil
        persistOrBlock()
    }

    func duplicateSelectedDevice() {
        guard var device = selectedDevice else { return }
        device.id = UUID().uuidString.lowercased()
        device.name += " copia"
        document.devices.append(device)
        selectedDeviceID = device.id
        deviceValidationMessage = nil
        persistOrBlock()
    }

    func updateSelectedDevice(_ mutation: (inout DeviceDefinition) -> Void) {
        guard let selectedDeviceID,
              let index = document.devices.firstIndex(where: { $0.id == selectedDeviceID })
        else { return }
        var candidate = document.devices[index]
        mutation(&candidate)
        do {
            _ = try candidate.resolved()
            document.devices[index] = candidate
            try persist()
            deviceValidationMessage = nil
        } catch {
            deviceValidationMessage = error.localizedDescription
        }
    }

    func removeSelectedDevice() {
        guard let selectedDeviceID else { return }
        document.devices.removeAll { $0.id == selectedDeviceID }
        self.selectedDeviceID = document.devices.first?.id
        deviceValidationMessage = nil
        persistOrBlock()
    }

    private func persistOrBlock() {
        do { try persist() } catch { blockedError = error.localizedDescription }
    }

    private func persist() throws {
        try persist(document)
    }

    private func persist(_ document: GlobalLibraryDocument) throws {
        guard let store else { throw GlobalLibraryError.inaccessible("La biblioteca global no tiene destino.") }
        try store.save(document)
    }
}
