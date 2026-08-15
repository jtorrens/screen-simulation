import AppKit
import CoreGraphics
import Foundation
import ImageIO
import StudioColor
import UniformTypeIdentifiers

struct SavedSceneAsset: Codable, Equatable, Sendable {
    let fileName: String
    let sha256: String

    func validate() throws {
        guard !fileName.isEmpty, sha256.count == 64, sha256.allSatisfy(\.isHexDigit) else {
            throw SceneLibraryError.invalidDocument("Una fuente guardada no tiene identidad completa.")
        }
    }
}

struct SavedMissingMediaDescriptor: Codable, Equatable, Sendable {
    let originalName: String
    let width: Int
    let height: Int
    let frameRateNumerator: UInt32
    let frameRateDenominator: UInt32
    let frameCount: Int
    let durationNumerator: UInt64
    let durationDenominator: UInt32

    var exactFrameRate: ExactFrameRate {
        get throws {
            try ExactFrameRate(
                numerator: frameRateNumerator,
                denominator: frameRateDenominator
            )
        }
    }

    func validate() throws {
        guard !originalName.isEmpty, width > 0, height > 0,
              frameRateNumerator > 0, frameRateDenominator > 0, frameCount > 0,
              durationDenominator > 0
        else {
            throw SceneLibraryError.invalidDocument(
                "La descripción persistida del medio ausente no es válida."
            )
        }
    }
}

struct SavedSceneSource: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case syntheticPattern, managedMedia }
    let kind: Kind
    let patternRawValue: UInt32?
    let assets: [SavedSceneAsset]
    let missingMedia: SavedMissingMediaDescriptor?

    func validate() throws {
        switch kind {
        case .syntheticPattern:
            guard let patternRawValue, SyntheticPattern(rawValue: patternRawValue) != nil,
                  assets.isEmpty, missingMedia == nil else {
                throw SceneLibraryError.invalidDocument("La fuente sintética guardada no es válida.")
            }
        case .managedMedia:
            guard patternRawValue == nil, !assets.isEmpty, let missingMedia else {
                throw SceneLibraryError.invalidDocument("La escena no contiene sus medios fuente.")
            }
            try assets.forEach { try $0.validate() }
            try missingMedia.validate()
        }
    }
}

struct SavedSceneSnapshot: Codable, Equatable, Sendable {
    static let schema = "ScreenSimulation.SavedScene.v3"
    let schema: String
    let source: SavedSceneSource
    let currentFrame: Int
    let viewerZoom: Double
    let viewerPanX: Double
    let viewerPanY: Double
    let viewerIsFitted: Bool
    let settingsDocument: Data

    init(
        source: SavedSceneSource,
        currentFrame: Int,
        viewerZoom: Double,
        viewerPanX: Double,
        viewerPanY: Double,
        viewerIsFitted: Bool,
        settingsDocument: Data
    ) {
        schema = Self.schema
        self.source = source
        self.currentFrame = currentFrame
        self.viewerZoom = viewerZoom
        self.viewerPanX = viewerPanX
        self.viewerPanY = viewerPanY
        self.viewerIsFitted = viewerIsFitted
        self.settingsDocument = settingsDocument
    }

    func validate() throws {
        guard schema == Self.schema, currentFrame >= 0,
              viewerZoom.isFinite, viewerZoom > 0,
              viewerPanX.isFinite, viewerPanY.isFinite,
              !settingsDocument.isEmpty,
              let object = try JSONSerialization.jsonObject(with: settingsDocument)
                as? [String: Any],
              object["settings"] is [String: Any]
        else { throw SceneLibraryError.invalidDocument("El snapshot de escena no es válido.") }
        try source.validate()
    }
}

struct SavedScene: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    let thumbnailFileName: String
    var snapshot: SavedSceneSnapshot

    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              thumbnailFileName == "\(id.uuidString.lowercased()).png"
        else { throw SceneLibraryError.invalidDocument("La escena necesita nombre y miniatura estables.") }
        try snapshot.validate()
    }
}

struct SavedSceneCapture: Sendable {
    let snapshot: SavedSceneSnapshot
    let thumbnailPNG: Data
}

struct SceneLibraryDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 3
    let schemaVersion: Int
    var scenes: [SavedScene]

    init(scenes: [SavedScene] = []) {
        schemaVersion = Self.currentSchemaVersion
        self.scenes = scenes
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SceneLibraryError.unsupportedSchema(schemaVersion)
        }
        guard Set(scenes.map(\.id)).count == scenes.count else {
            throw SceneLibraryError.invalidDocument("Hay identidades de escena duplicadas.")
        }
        try scenes.forEach { try $0.validate() }
    }
}

enum SceneLibraryError: LocalizedError {
    case unsupportedSchema(Int)
    case invalidDocument(String)
    case inaccessible(String)

    var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version):
            "La biblioteca de escenas usa el esquema \(version); esta versión exige \(SceneLibraryDocument.currentSchemaVersion). Ejecuta la migración de mantenimiento correspondiente."
        case let .invalidDocument(message), let .inaccessible(message): message
        }
    }
}

struct SceneLibraryStore: Sendable {
    let directoryURL: URL
    let documentURL: URL

    init(directoryURL: URL? = nil) throws {
        let directory: URL
        if let directoryURL {
            directory = directoryURL
        } else {
            let root = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            directory = root
                .appendingPathComponent("SCREEN-SIMULATION", isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
                .appendingPathComponent("Scenes", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directoryURL = directory
        documentURL = directory.appendingPathComponent("Scenes.v3.json")
    }

    func load() throws -> SceneLibraryDocument {
        guard FileManager.default.fileExists(atPath: documentURL.path) else {
            return SceneLibraryDocument()
        }
        let data = try Data(contentsOf: documentURL)
        try validateStrictShape(data)
        let document = try JSONDecoder().decode(SceneLibraryDocument.self, from: data)
        try document.validate()
        for scene in document.scenes {
            guard FileManager.default.fileExists(
                atPath: thumbnailURL(for: scene).path
            ) else {
                throw SceneLibraryError.invalidDocument(
                    "Falta la miniatura obligatoria de “\(scene.name)”."
                )
            }
        }
        return document
    }

    func save(_ document: SceneLibraryDocument) throws {
        try document.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: documentURL, options: .atomic)
    }

    func thumbnailURL(for scene: SavedScene) -> URL {
        directoryURL.appendingPathComponent(scene.thumbnailFileName)
    }

    func writeThumbnail(_ data: Data, for scene: SavedScene) throws {
        guard !data.isEmpty else {
            throw SceneLibraryError.invalidDocument("La miniatura de escena está vacía.")
        }
        try data.write(to: thumbnailURL(for: scene), options: .atomic)
    }

    func removeThumbnail(for scene: SavedScene) throws {
        let url = thumbnailURL(for: scene)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SceneLibraryError.invalidDocument("Falta la miniatura de ‘\(scene.name)’.")
        }
        try FileManager.default.removeItem(at: url)
    }

    private func validateStrictShape(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["schemaVersion", "scenes"],
              let scenes = root["scenes"] as? [[String: Any]]
        else { throw SceneLibraryError.invalidDocument("Contrato de biblioteca desconocido.") }
        for scene in scenes {
            guard Set(scene.keys) == ["id", "name", "thumbnailFileName", "snapshot"],
                  let snapshot = scene["snapshot"] as? [String: Any],
                  Set(snapshot.keys) == [
                      "schema", "source", "currentFrame", "viewerZoom", "viewerPanX",
                      "viewerPanY", "viewerIsFitted", "settingsDocument",
                  ],
                  let source = snapshot["source"] as? [String: Any],
                  Set(source.keys) == ["kind", "assets", "missingMedia"]
                    || Set(source.keys) == ["kind", "patternRawValue", "assets"],
                  let assets = source["assets"] as? [[String: Any]],
                  assets.allSatisfy({ Set($0.keys) == ["fileName", "sha256"] }),
                  (source["missingMedia"] == nil || {
                      guard let missing = source["missingMedia"] as? [String: Any] else {
                          return false
                      }
                      return Set(missing.keys) == [
                          "originalName", "width", "height", "frameRateNumerator",
                          "frameRateDenominator", "frameCount", "durationNumerator",
                          "durationDenominator",
                      ]
                  }())
            else { throw SceneLibraryError.invalidDocument("La escena contiene campos desconocidos.") }
        }
    }
}

enum SceneThumbnailRenderer {
    @MainActor
    static func render(
        frame: StudioColorMetalFrame,
        output: StudioColorOutputTransform,
        display: StudioColorMetalDisplay,
        maximumSize: CGSize = .init(width: 320, height: 180)
    ) throws -> Data {
        let rgba = try display.renderRGBA8(frame, output: output)
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let source = CGImage(
                width: frame.width,
                height: frame.height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: frame.width * 4,
                space: output.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              )
        else { throw SceneLibraryError.invalidDocument("No se pudo crear la miniatura.") }
        let scale = min(
            maximumSize.width / CGFloat(source.width),
            maximumSize.height / CGFloat(source.height),
            1
        )
        let width = max(1, Int((CGFloat(source.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(source.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: output.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw SceneLibraryError.invalidDocument("No se pudo reducir la miniatura.") }
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else {
            throw SceneLibraryError.invalidDocument("No se pudo publicar la miniatura.")
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else { throw SceneLibraryError.invalidDocument("No se pudo codificar la miniatura.") }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SceneLibraryError.invalidDocument("No se pudo cerrar la miniatura.")
        }
        return data as Data
    }
}

@MainActor
final class SceneLibraryController: ObservableObject {
    @Published private(set) var document = SceneLibraryDocument()
    @Published private(set) var blockedError: String?
    private let store: SceneLibraryStore?

    init(store: SceneLibraryStore? = try? SceneLibraryStore()) {
        self.store = store
        guard let store else {
            blockedError = "No se puede abrir la biblioteca de escenas."
            return
        }
        do { document = try store.load() }
        catch { blockedError = error.localizedDescription }
    }

    func thumbnailURL(for scene: SavedScene) -> URL? {
        store?.thumbnailURL(for: scene)
    }

    func add(snapshot: SavedSceneSnapshot, thumbnail: Data) throws {
        guard let store else { throw SceneLibraryError.inaccessible("Sin destino de escenas.") }
        let id = UUID()
        let scene = SavedScene(
            id: id,
            name: "Escena \(document.scenes.count + 1)",
            thumbnailFileName: "\(id.uuidString.lowercased()).png",
            snapshot: snapshot
        )
        try scene.validate()
        try store.writeThumbnail(thumbnail, for: scene)
        var candidate = document
        candidate.scenes.insert(scene, at: 0)
        do {
            try store.save(candidate)
            document = candidate
        } catch {
            try? store.removeThumbnail(for: scene)
            throw error
        }
    }

    func rename(_ scene: SavedScene, to name: String) throws {
        guard let store, let index = document.scenes.firstIndex(where: { $0.id == scene.id })
        else { throw SceneLibraryError.inaccessible("La escena ya no existe.") }
        var candidate = document
        candidate.scenes[index].name = name
        try store.save(candidate)
        document = candidate
    }

    func update(_ scene: SavedScene, snapshot: SavedSceneSnapshot, thumbnail: Data) throws {
        guard let store, let index = document.scenes.firstIndex(where: { $0.id == scene.id })
        else { throw SceneLibraryError.inaccessible("La escena ya no existe.") }
        var candidate = document
        candidate.scenes[index].snapshot = snapshot
        try candidate.scenes[index].validate()
        let thumbnailURL = store.thumbnailURL(for: candidate.scenes[index])
        let previousThumbnail = try Data(contentsOf: thumbnailURL)
        do {
            try store.writeThumbnail(thumbnail, for: candidate.scenes[index])
            try store.save(candidate)
        } catch {
            try? previousThumbnail.write(to: thumbnailURL, options: .atomic)
            throw error
        }
        document = candidate
    }

    func delete(_ scene: SavedScene) throws {
        guard let store, document.scenes.contains(where: { $0.id == scene.id })
        else { throw SceneLibraryError.inaccessible("La escena ya no existe.") }
        var candidate = document
        candidate.scenes.removeAll { $0.id == scene.id }
        try store.save(candidate)
        try store.removeThumbnail(for: scene)
        document = candidate
    }
}
