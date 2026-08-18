import AppKit
import Foundation
import StudioColor
import StudioMedia
import UniformTypeIdentifiers

struct LibraryColorModeOption: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
}

@dynamicMemberLookup
struct LibraryItem<Value>: Codable, Equatable, Identifiable, Sendable
where Value: Codable & Equatable & Identifiable & Sendable,
      Value.ID: Codable & Hashable & Sendable {
    var value: Value
    var isLocked: Bool

    var id: Value.ID { value.id }

    subscript<Member>(dynamicMember keyPath: KeyPath<Value, Member>) -> Member {
        value[keyPath: keyPath]
    }
}

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
            throw GlobalLibraryError.invalidEntity("El Input Transform de \(name) no existe en StudioColor.")
        }
        guard !bookmark.isEmpty else {
            throw GlobalLibraryError.invalidEntity("La imagen de prueba \(name) no contiene bookmark.")
        }
    }
}

struct GlobalPatternDefinition: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var pattern: SyntheticPattern

    static let builtIns = SyntheticPattern.allCases.map {
        Self(id: "screen-pattern-\($0.rawValue)", name: $0.label, pattern: $0)
    }

    func validate() throws {
        guard !id.isEmpty, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GlobalLibraryError.invalidEntity("El patrón necesita identidad y nombre.")
        }
    }
}

struct GlobalLibraryDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 10
    let schemaVersion: Int
    var patterns: [LibraryItem<GlobalPatternDefinition>]
    var testImages: [LibraryItem<GlobalTestImage>]
    var renderPresets: [LibraryItem<StudioRenderPreset>]
    var devices: [LibraryItem<DeviceDefinition>]
    var coverGlasses: [LibraryItem<CoverGlassDefinition>]

    init(
        patterns: [GlobalPatternDefinition] = GlobalPatternDefinition.builtIns,
        testImages: [GlobalTestImage] = [],
        renderPresets: [StudioRenderPreset] = StudioRenderPreset.builtIns,
        devices: [DeviceDefinition] = [],
        coverGlasses: [CoverGlassDefinition] = []
    ) {
        schemaVersion = Self.currentSchemaVersion
        let patternSeedIDs = Set(GlobalPatternDefinition.builtIns.map(\.id))
        self.patterns = patterns.map {
            .init(value: $0, isLocked: patternSeedIDs.contains($0.id))
        }
        self.testImages = testImages.map { .init(value: $0, isLocked: false) }
        let renderSeedIDs = Set(StudioRenderPreset.builtIns.map(\.id))
        self.renderPresets = renderPresets.map {
            .init(value: $0, isLocked: renderSeedIDs.contains($0.id))
        }
        let deviceSeedIDs = Set((try? RustDeviceCatalog.builtIns().map(\.id)) ?? [])
        self.devices = devices.map {
            .init(value: $0, isLocked: deviceSeedIDs.contains($0.id))
        }
        let coverSeedIDs = Set((try? RustCoverGlassCatalog.builtIns().map(\.id)) ?? [])
        self.coverGlasses = coverGlasses.map {
            .init(value: $0, isLocked: coverSeedIDs.contains($0.id))
        }
    }

    private init(
        patternItems: [LibraryItem<GlobalPatternDefinition>],
        testImageItems: [LibraryItem<GlobalTestImage>],
        renderPresetItems: [LibraryItem<StudioRenderPreset>],
        deviceItems: [LibraryItem<DeviceDefinition>],
        coverGlassItems: [LibraryItem<CoverGlassDefinition>]
    ) {
        schemaVersion = Self.currentSchemaVersion
        patterns = patternItems
        testImages = testImageItems
        renderPresets = renderPresetItems
        devices = deviceItems
        coverGlasses = coverGlassItems
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw GlobalLibraryError.unsupportedSchema(schemaVersion)
        }
        guard Set(patterns.map(\.id)).count == patterns.count,
              Set(testImages.map(\.id)).count == testImages.count,
              Set(renderPresets.map(\.id)).count == renderPresets.count,
              Set(devices.map(\.id)).count == devices.count,
              Set(coverGlasses.map(\.id)).count == coverGlasses.count
        else { throw GlobalLibraryError.invalidEntity("Hay identificadores globales duplicados.") }
        try patterns.forEach { try $0.value.validate() }
        try testImages.forEach { try $0.value.validate() }
        try devices.forEach { _ = try $0.value.resolved() }
        try coverGlasses.forEach { try $0.value.validate() }
        let coverGlassIDs = Set(coverGlasses.map(\.id))
        guard devices.allSatisfy({
            coverGlassIDs.contains($0.defaultCoverGlassPresetID)
        }) else {
            throw GlobalLibraryError.invalidEntity(
                "Un Device referencia un Cover Glass que no existe en la biblioteca."
            )
        }
        guard renderPresets.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw GlobalLibraryError.invalidEntity("Todos los presets necesitan nombre.")
        }
        let resolvedRenderPresets = renderPresets.map(\.value)
        let renderContractsAreValid = resolvedRenderPresets.allSatisfy { preset in
            let encodingIsValid = preset.format.supportedPixelEncodings
                .contains(preset.pixelEncoding)
            let rangeIsValid = preset.format
                .supportedSignalRanges(for: preset.pixelEncoding)
                .contains(preset.signalRange)
            let alphaIsValid = preset.format.supportsAlpha || preset.alpha == .ignore
            let audioIsValid = preset.format.isMovie || !preset.includeAudio
            let odtIsValid = if preset.target == .sdr || preset.target == .hdr {
                preset.display != nil && preset.view != nil
            } else {
                preset.display == nil && preset.view == nil
            }
            return encodingIsValid && rangeIsValid && alphaIsValid
                && audioIsValid && odtIsValid
        }
        guard renderContractsAreValid else {
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
                devices: try RustDeviceCatalog.builtIns(),
                coverGlasses: try RustCoverGlassCatalog.builtIns()
            )
            try document.validate()
            return document
        }
        let data = try Data(contentsOf: documentURL)
        let version = try JSONDecoder().decode(
            GlobalLibrarySchemaHeader.self,
            from: data
        ).schemaVersion
        guard version == GlobalLibraryDocument.currentSchemaVersion else {
            throw GlobalLibraryError.unsupportedSchema(version)
        }
        let document = try JSONDecoder().decode(GlobalLibraryDocument.self, from: data)
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

private struct GlobalLibrarySchemaHeader: Decodable {
    let schemaVersion: Int
}

@MainActor
final class GlobalLibraryController: ObservableObject {
    @Published private(set) var document = GlobalLibraryDocument()
    @Published var selectedPatternID: String?
    @Published var selectedImageID: UUID?
    @Published var selectedPresetID: UUID?
    @Published var selectedDeviceID: String?
    @Published var selectedCoverGlassID: String?
    @Published private(set) var deviceValidationMessage: String?
    @Published private(set) var coverGlassValidationMessage: String?
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
            selectedPatternID = document.patterns.first?.id
            selectedImageID = document.testImages.first?.id
            selectedPresetID = allRenderPresets.first?.id
            selectedDeviceID = document.devices.first?.id
            selectedCoverGlassID = document.coverGlasses.first?.id
        } catch {
            blockedError = error.localizedDescription
        }
    }

    var allRenderPresets: [StudioRenderPreset] {
        let builtInIDs = Set(StudioRenderPreset.builtIns.map(\.id))
        let custom = document.renderPresets
            .map(\.value)
            .filter { !builtInIDs.contains($0.id) }
        return StudioRenderPreset.builtIns + custom
    }

    var authorableColorModes: [LibraryColorModeOption] {
        StudioColorMode.catalog.map { .init(id: $0.id, label: $0.label) }
    }

    func colorModes(for device: DeviceDefinition) -> [LibraryColorModeOption] {
        device.colorModeIDs.compactMap { id in
            authorableColorModes.first(where: { $0.id == id })
        }
    }

    var selectedDevice: DeviceDefinition? {
        selectedDeviceItem?.value
    }

    var selectedCoverGlass: CoverGlassDefinition? {
        selectedCoverGlassItem?.value
    }

    var selectedPatternItem: LibraryItem<GlobalPatternDefinition>? {
        document.patterns.first { $0.id == selectedPatternID }
    }

    var selectedImageItem: LibraryItem<GlobalTestImage>? {
        document.testImages.first { $0.id == selectedImageID }
    }

    var selectedPresetItem: LibraryItem<StudioRenderPreset>? {
        document.renderPresets.first { $0.id == selectedPresetID }
    }

    var selectedDeviceItem: LibraryItem<DeviceDefinition>? {
        document.devices.first { $0.id == selectedDeviceID }
    }

    var selectedCoverGlassItem: LibraryItem<CoverGlassDefinition>? {
        document.coverGlasses.first { $0.id == selectedCoverGlassID }
    }

    func addPattern() {
        guard var pattern = GlobalPatternDefinition.builtIns.first else { return }
        pattern.id = UUID().uuidString.lowercased()
        pattern.name = "Patrón personalizado"
        document.patterns.append(.init(value: pattern, isLocked: false))
        selectedPatternID = pattern.id
        persistOrBlock()
    }

    func duplicateSelectedPattern() {
        guard var pattern = selectedPatternItem?.value else { return }
        pattern.id = UUID().uuidString.lowercased()
        pattern.name += " copia"
        document.patterns.append(.init(value: pattern, isLocked: false))
        selectedPatternID = pattern.id
        persistOrBlock()
    }

    func updateSelectedPattern(_ mutation: (inout GlobalPatternDefinition) -> Void) {
        guard let index = document.patterns.firstIndex(where: { $0.id == selectedPatternID }),
              !document.patterns[index].isLocked else { return }
        var candidate = document
        mutation(&candidate.patterns[index].value)
        do {
            try candidate.validate()
            try persist(candidate)
            document = candidate
        } catch {
            blockedError = error.localizedDescription
        }
    }

    func unlockSelectedPattern() {
        guard let index = document.patterns.firstIndex(where: { $0.id == selectedPatternID })
        else { return }
        document.patterns[index].isLocked = false
        persistOrBlock()
    }

    func removeSelectedPattern() {
        guard let selectedPatternID,
              selectedPatternItem?.isLocked == false else { return }
        document.patterns.removeAll { $0.id == selectedPatternID }
        self.selectedPatternID = document.patterns.first?.id
        persistOrBlock()
    }

    func addTestImage() {
        guard blockedError == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, UTType(filenameExtension: "exr")!]
        FileDialogDirectory.libraryTestImage.apply(to: panel)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        FileDialogDirectory.libraryTestImage.remember(url)
        do {
            let bookmark = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let entry = GlobalTestImage(
                id: UUID(), name: url.deletingPathExtension().lastPathComponent,
                bookmark: bookmark,
                inputTransformID: url.pathExtension.lowercased() == "exr" ? "acescg" : "srgb-encoded-rec709",
                alpha: .straight, matrix: .bt709, range: .full
            )
            document.testImages.append(.init(value: entry, isLocked: false))
            selectedImageID = entry.id
            try persist()
        } catch { blockedError = error.localizedDescription }
    }

    func updateSelectedImage(_ mutation: (inout GlobalTestImage) -> Void) {
        guard let selectedImageID,
              let index = document.testImages.firstIndex(where: { $0.id == selectedImageID }),
              !document.testImages[index].isLocked
        else { return }
        mutation(&document.testImages[index].value)
        persistOrBlock()
    }

    func duplicateSelectedImage() {
        guard var image = selectedImageItem?.value else { return }
        image = GlobalTestImage(
            id: UUID(), name: image.name + " copia", bookmark: image.bookmark,
            inputTransformID: image.inputTransformID, alpha: image.alpha,
            matrix: image.matrix, range: image.range
        )
        document.testImages.append(.init(value: image, isLocked: false))
        selectedImageID = image.id
        persistOrBlock()
    }

    func unlockSelectedImage() {
        guard let index = document.testImages.firstIndex(where: { $0.id == selectedImageID })
        else { return }
        document.testImages[index].isLocked = false
        persistOrBlock()
    }

    func removeSelectedImage() {
        guard let selectedImageID,
              selectedImageItem?.isLocked == false else { return }
        document.testImages.removeAll { $0.id == selectedImageID }
        self.selectedImageID = document.testImages.first?.id
        persistOrBlock()
    }

    func addRenderPreset() {
        var preset = StudioRenderPreset.builtIns[0]
        preset.id = UUID()
        preset.name = "Preset personalizado"
        document.renderPresets.append(.init(value: preset, isLocked: false))
        selectedPresetID = preset.id
        persistOrBlock()
    }

    func duplicateSelectedPreset() {
        guard let selectedPresetID,
              var preset = allRenderPresets.first(where: { $0.id == selectedPresetID })
        else { return }
        preset.id = UUID()
        preset.name += " copia"
        document.renderPresets.append(.init(value: preset, isLocked: false))
        self.selectedPresetID = preset.id
        persistOrBlock()
    }

    func updateSelectedPreset(_ mutation: (inout StudioRenderPreset) -> Void) {
        guard let selectedPresetID,
              let index = document.renderPresets.firstIndex(where: { $0.id == selectedPresetID }),
              !document.renderPresets[index].isLocked
        else { return }
        var candidate = document
        mutation(&candidate.renderPresets[index].value)
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
        guard let selectedPresetID,
              selectedPresetItem?.isLocked == false else { return }
        document.renderPresets.removeAll { $0.id == selectedPresetID }
        self.selectedPresetID = document.renderPresets.first?.id
        persistOrBlock()
    }

    func unlockSelectedPreset() {
        guard let index = document.renderPresets.firstIndex(where: { $0.id == selectedPresetID })
        else { return }
        document.renderPresets[index].isLocked = false
        persistOrBlock()
    }

    func addDevice() {
        guard let catalog = try? RustDeviceCatalog.builtIns(),
              var device = catalog.first
        else { return }
        device.id = UUID().uuidString.lowercased()
        device.name = "Device personalizado"
        document.devices.append(.init(value: device, isLocked: false))
        selectedDeviceID = device.id
        deviceValidationMessage = nil
        persistOrBlock()
    }

    func duplicateSelectedDevice() {
        guard var device = selectedDevice else { return }
        device.id = UUID().uuidString.lowercased()
        device.name += " copia"
        document.devices.append(.init(value: device, isLocked: false))
        selectedDeviceID = device.id
        deviceValidationMessage = nil
        persistOrBlock()
    }

    func updateSelectedDevice(_ mutation: (inout DeviceDefinition) -> Void) {
        guard let selectedDeviceID,
              let index = document.devices.firstIndex(where: { $0.id == selectedDeviceID }),
              !document.devices[index].isLocked
        else { return }
        var candidate = document
        mutation(&candidate.devices[index].value)
        do {
            _ = try candidate.devices[index].value.resolved()
            try candidate.validate()
            try persist(candidate)
            document = candidate
            deviceValidationMessage = nil
        } catch {
            deviceValidationMessage = error.localizedDescription
        }
    }

    func removeSelectedDevice() {
        guard let selectedDeviceID,
              selectedDeviceItem?.isLocked == false else { return }
        document.devices.removeAll { $0.id == selectedDeviceID }
        self.selectedDeviceID = document.devices.first?.id
        deviceValidationMessage = nil
        persistOrBlock()
    }

    func unlockSelectedDevice() {
        guard let index = document.devices.firstIndex(where: { $0.id == selectedDeviceID })
        else { return }
        document.devices[index].isLocked = false
        persistOrBlock()
    }

    func addCoverGlass() {
        guard var cover = (try? RustCoverGlassCatalog.builtIns())?.first else { return }
        cover.id = UUID().uuidString.lowercased()
        cover.name = "Cover Glass personalizado"
        document.coverGlasses.append(.init(value: cover, isLocked: false))
        selectedCoverGlassID = cover.id
        coverGlassValidationMessage = nil
        persistOrBlock()
    }

    func duplicateSelectedCoverGlass() {
        guard var cover = selectedCoverGlass else { return }
        cover.id = UUID().uuidString.lowercased()
        cover.name += " copia"
        document.coverGlasses.append(.init(value: cover, isLocked: false))
        selectedCoverGlassID = cover.id
        coverGlassValidationMessage = nil
        persistOrBlock()
    }

    func updateSelectedCoverGlass(
        _ mutation: (inout CoverGlassDefinition) -> Void
    ) {
        guard let index = document.coverGlasses.firstIndex(
            where: { $0.id == selectedCoverGlassID }
        ), !document.coverGlasses[index].isLocked else { return }
        var candidate = document.coverGlasses[index].value
        mutation(&candidate)
        do {
            try candidate.validate()
            document.coverGlasses[index].value = candidate
            try persist()
            coverGlassValidationMessage = nil
        } catch {
            coverGlassValidationMessage = error.localizedDescription
        }
    }

    func removeSelectedCoverGlass() {
        guard let selectedCoverGlassID,
              selectedCoverGlassItem?.isLocked == false else { return }
        var candidate = document
        candidate.coverGlasses.removeAll { $0.id == selectedCoverGlassID }
        do {
            try candidate.validate()
            try persist(candidate)
            document = candidate
            self.selectedCoverGlassID = document.coverGlasses.first?.id
            coverGlassValidationMessage = nil
        } catch {
            coverGlassValidationMessage = error.localizedDescription
        }
    }

    func unlockSelectedCoverGlass() {
        guard let index = document.coverGlasses.firstIndex(
            where: { $0.id == selectedCoverGlassID }
        ) else { return }
        document.coverGlasses[index].isLocked = false
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
