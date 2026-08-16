import AppKit
import CoreGraphics
import CryptoKit
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

struct SavedTrackingCalibration: Codable, Equatable, Sendable {
    let pointAID: String
    let pointBID: String
    let measuredDistanceMeters: Double
    let metersPerSourceUnit: Double

    func validate() throws {
        guard !pointAID.isEmpty, !pointBID.isEmpty, pointAID != pointBID,
              measuredDistanceMeters.isFinite, measuredDistanceMeters > 0,
              metersPerSourceUnit.isFinite, metersPerSourceUnit > 0 else {
            throw SceneLibraryError.invalidDocument("La calibración métrica del tracking no es válida.")
        }
    }
}

struct SavedTrackingScene: Codable, Equatable, Sendable {
    let asset: SavedSceneAsset
    let cameraID: String
    let pointGroupID: String
    let visibleMeshIDs: [String]
    let pointsVisible: Bool
    let geometryVisible: Bool
    let cameraEnabled: Bool
    let calibration: SavedTrackingCalibration

    func validate() throws {
        try asset.validate()
        guard !cameraID.isEmpty, !pointGroupID.isEmpty,
              Set(visibleMeshIDs).count == visibleMeshIDs.count else {
            throw SceneLibraryError.invalidDocument("La selección de tracking guardada no es válida.")
        }
        try calibration.validate()
    }
}

struct SavedSceneSnapshot: Codable, Equatable, Sendable {
    static let schema = "ScreenSimulation.SavedScene.v11"
    let schema: String
    let source: SavedSceneSource
    let currentFrame: Int
    let viewerZoom: Double
    let viewerPanX: Double
    let viewerPanY: Double
    let viewerIsFitted: Bool
    let settingsDocument: Data
    let generatedEnvironment: SavedSceneAsset?
    let tracking: SavedTrackingScene?

    private enum CodingKeys: String, CodingKey {
        case schema, source, currentFrame, viewerZoom, viewerPanX, viewerPanY
        case viewerIsFitted, settingsDocument, generatedEnvironment, tracking
    }

    init(
        source: SavedSceneSource,
        currentFrame: Int,
        viewerZoom: Double,
        viewerPanX: Double,
        viewerPanY: Double,
        viewerIsFitted: Bool,
        settingsDocument: Data,
        generatedEnvironment: SavedSceneAsset? = nil,
        tracking: SavedTrackingScene? = nil
    ) {
        schema = Self.schema
        self.source = source
        self.currentFrame = currentFrame
        self.viewerZoom = viewerZoom
        self.viewerPanX = viewerPanX
        self.viewerPanY = viewerPanY
        self.viewerIsFitted = viewerIsFitted
        self.settingsDocument = settingsDocument
        self.generatedEnvironment = generatedEnvironment
        self.tracking = tracking
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decode(String.self, forKey: .schema)
        source = try values.decode(SavedSceneSource.self, forKey: .source)
        currentFrame = try values.decode(Int.self, forKey: .currentFrame)
        viewerZoom = try values.decode(Double.self, forKey: .viewerZoom)
        viewerPanX = try values.decode(Double.self, forKey: .viewerPanX)
        viewerPanY = try values.decode(Double.self, forKey: .viewerPanY)
        viewerIsFitted = try values.decode(Bool.self, forKey: .viewerIsFitted)
        settingsDocument = try values.decode(Data.self, forKey: .settingsDocument)
        generatedEnvironment = try values.decodeIfPresent(
            SavedSceneAsset.self, forKey: .generatedEnvironment
        )
        tracking = try values.decodeIfPresent(SavedTrackingScene.self, forKey: .tracking)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schema, forKey: .schema)
        try values.encode(source, forKey: .source)
        try values.encode(currentFrame, forKey: .currentFrame)
        try values.encode(viewerZoom, forKey: .viewerZoom)
        try values.encode(viewerPanX, forKey: .viewerPanX)
        try values.encode(viewerPanY, forKey: .viewerPanY)
        try values.encode(viewerIsFitted, forKey: .viewerIsFitted)
        try values.encode(settingsDocument, forKey: .settingsDocument)
        if let generatedEnvironment {
            try values.encode(generatedEnvironment, forKey: .generatedEnvironment)
        } else {
            try values.encodeNil(forKey: .generatedEnvironment)
        }
        if let tracking { try values.encode(tracking, forKey: .tracking) }
        else { try values.encodeNil(forKey: .tracking) }
    }

    func validate() throws {
        guard schema == Self.schema, currentFrame >= 0,
              viewerZoom.isFinite, viewerZoom > 0,
              viewerPanX.isFinite, viewerPanY.isFinite,
              !settingsDocument.isEmpty,
              let object = try JSONSerialization.jsonObject(with: settingsDocument)
                as? [String: Any],
              let settings = object["settings"] as? [String: Any],
              settings["schema"] as? String == PhysicalSettingsExchange.schema
        else { throw SceneLibraryError.invalidDocument("El snapshot de escena no es válido.") }
        try source.validate()
        try generatedEnvironment?.validate()
        try tracking?.validate()
    }

    func replacingGeneratedEnvironment(_ asset: SavedSceneAsset?) throws -> Self {
        guard let asset else {
            return Self(
                source: source, currentFrame: currentFrame, viewerZoom: viewerZoom,
                viewerPanX: viewerPanX, viewerPanY: viewerPanY,
                viewerIsFitted: viewerIsFitted, settingsDocument: settingsDocument,
                generatedEnvironment: nil,
                tracking: tracking
            )
        }
        var root = try requireObject(settingsDocument)
        guard var settings = root["settings"] as? [String: Any],
              var context = settings["context"] as? [String: Any],
              var environment = context["environmentResource"] as? [String: Any]
        else { throw SceneLibraryError.invalidDocument("La escena no contiene el recurso de entorno.") }
        environment["kind"] = "image"
        environment["fileName"] = asset.fileName
        environment["sha256"] = asset.sha256
        environment["inputTransformID"] = "acescg"
        context["environmentResource"] = environment
        settings["context"] = context
        root["settings"] = settings
        let data = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return Self(
            source: source, currentFrame: currentFrame, viewerZoom: viewerZoom,
            viewerPanX: viewerPanX, viewerPanY: viewerPanY,
            viewerIsFitted: viewerIsFitted, settingsDocument: data,
            generatedEnvironment: asset,
            tracking: tracking
        )
    }
}

private func requireObject(_ data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw SceneLibraryError.invalidDocument("Los ajustes de escena no son un objeto.")
    }
    return object
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
        if let asset = snapshot.generatedEnvironment,
           asset.fileName != "scene-\(id.uuidString.lowercased()).exr" {
            throw SceneLibraryError.invalidDocument("El entorno generado pertenece a otra escena.")
        }
    }
}

struct SavedSceneCapture: Sendable {
    let snapshot: SavedSceneSnapshot
    let thumbnailPNG: Data
    let generatedEnvironmentEXR: Data?
}

struct SceneLibraryDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 11
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
    let environmentLibraryRoot: URL?
    let trackingLibraryRoot: URL?

    init(
        directoryURL: URL? = nil,
        environmentLibraryRoot: URL? = nil,
        trackingLibraryRoot: URL? = nil
    ) throws {
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
        self.environmentLibraryRoot = environmentLibraryRoot
        self.trackingLibraryRoot = trackingLibraryRoot
        documentURL = directory.appendingPathComponent("Scenes.v11.json")
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
            if let asset = scene.snapshot.generatedEnvironment {
                guard try EnvironmentAssetLibrary.asset(
                    sha256: asset.sha256,
                    originalFileName: asset.fileName,
                    libraryRoot: environmentLibraryRoot
                ) != nil else {
                    throw SceneLibraryError.invalidDocument(
                        "Falta el entorno generado de “\(scene.name)”."
                    )
                }
            }
            if let tracking = scene.snapshot.tracking {
                guard try TrackingAssetLibrary.asset(
                    sha256: tracking.asset.sha256,
                    originalFileName: tracking.asset.fileName,
                    libraryRoot: trackingLibraryRoot
                ) != nil else {
                    throw SceneLibraryError.invalidDocument(
                        "Falta la composición Fusion de tracking de “\(scene.name)”."
                    )
                }
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
                      "generatedEnvironment", "tracking",
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
                  }()),
                  (snapshot["tracking"] == nil || snapshot["tracking"] is NSNull || {
                      guard let tracking = snapshot["tracking"] as? [String: Any],
                            Set(tracking.keys) == [
                                "asset", "cameraID", "pointGroupID", "visibleMeshIDs",
                                "pointsVisible", "geometryVisible", "cameraEnabled", "calibration",
                            ],
                            let asset = tracking["asset"] as? [String: Any],
                            Set(asset.keys) == ["fileName", "sha256"],
                            let calibration = tracking["calibration"] as? [String: Any],
                            Set(calibration.keys) == [
                                "pointAID", "pointBID", "measuredDistanceMeters", "metersPerSourceUnit",
                            ] else { return false }
                      return true
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

    func scene(id: UUID) -> SavedScene? {
        document.scenes.first { $0.id == id }
    }

    @discardableResult
    func add(capture: SavedSceneCapture) throws -> SavedScene {
        guard let store else { throw SceneLibraryError.inaccessible("Sin destino de escenas.") }
        let id = UUID()
        let asset = try capture.generatedEnvironmentEXR.map {
            let managed = try EnvironmentAssetLibrary.storeSceneGeneratedEXR(
                $0, sceneID: id, libraryRoot: store.environmentLibraryRoot
            )
            return SavedSceneAsset(fileName: managed.originalFileName, sha256: managed.sha256)
        }
        let snapshot = try capture.snapshot.replacingGeneratedEnvironment(asset)
        let scene = SavedScene(
            id: id,
            name: "Escena \(document.scenes.count + 1)",
            thumbnailFileName: "\(id.uuidString.lowercased()).png",
            snapshot: snapshot
        )
        try scene.validate()
        try store.writeThumbnail(capture.thumbnailPNG, for: scene)
        var candidate = document
        candidate.scenes.insert(scene, at: 0)
        do {
            try store.save(candidate)
            document = candidate
            return scene
        } catch {
            try? store.removeThumbnail(for: scene)
            if asset != nil {
                try? EnvironmentAssetLibrary.removeSceneGeneratedEXR(
                    sceneID: id, libraryRoot: store.environmentLibraryRoot
                )
            }
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

    func update(_ scene: SavedScene, capture: SavedSceneCapture) throws {
        guard let store, let index = document.scenes.firstIndex(where: { $0.id == scene.id })
        else { throw SceneLibraryError.inaccessible("La escena ya no existe.") }
        var candidate = document
        let previousAsset = scene.snapshot.generatedEnvironment
        let previousEnvironmentData = try previousAsset.flatMap {
            try EnvironmentAssetLibrary.asset(
                sha256: $0.sha256, originalFileName: $0.fileName,
                libraryRoot: store.environmentLibraryRoot
            ).map { try Data(contentsOf: $0.url, options: .mappedIfSafe) }
        }
        let asset = try capture.generatedEnvironmentEXR.map {
            let managed = try EnvironmentAssetLibrary.storeSceneGeneratedEXR(
                $0, sceneID: scene.id, libraryRoot: store.environmentLibraryRoot
            )
            return SavedSceneAsset(fileName: managed.originalFileName, sha256: managed.sha256)
        }
        candidate.scenes[index].snapshot = try capture.snapshot.replacingGeneratedEnvironment(asset)
        try candidate.scenes[index].validate()
        let thumbnailURL = store.thumbnailURL(for: candidate.scenes[index])
        let previousThumbnail = try Data(contentsOf: thumbnailURL)
        do {
            try store.writeThumbnail(capture.thumbnailPNG, for: candidate.scenes[index])
            try store.save(candidate)
        } catch {
            try? previousThumbnail.write(to: thumbnailURL, options: .atomic)
            if let previousEnvironmentData {
                _ = try? EnvironmentAssetLibrary.storeSceneGeneratedEXR(
                    previousEnvironmentData, sceneID: scene.id,
                    libraryRoot: store.environmentLibraryRoot
                )
            } else if asset != nil {
                try? EnvironmentAssetLibrary.removeSceneGeneratedEXR(
                    sceneID: scene.id, libraryRoot: store.environmentLibraryRoot
                )
            }
            throw error
        }
        if previousAsset != nil, asset == nil {
            try EnvironmentAssetLibrary.removeSceneGeneratedEXR(
                sceneID: scene.id, libraryRoot: store.environmentLibraryRoot
            )
        }
        document = candidate
    }

    func replaceGeneratedEnvironment(sceneID: UUID, data: Data) throws -> ManagedEnvironmentAsset {
        guard let store, let index = document.scenes.firstIndex(where: { $0.id == sceneID })
        else { throw SceneLibraryError.inaccessible("La escena ya no existe.") }
        let previousAsset = document.scenes[index].snapshot.generatedEnvironment
        let previousData = try previousAsset.flatMap {
            try EnvironmentAssetLibrary.asset(
                sha256: $0.sha256, originalFileName: $0.fileName,
                libraryRoot: store.environmentLibraryRoot
            ).map { try Data(contentsOf: $0.url, options: .mappedIfSafe) }
        }
        let managed = try EnvironmentAssetLibrary.storeSceneGeneratedEXR(
            data, sceneID: sceneID, libraryRoot: store.environmentLibraryRoot
        )
        let asset = SavedSceneAsset(fileName: managed.originalFileName, sha256: managed.sha256)
        var candidate = document
        candidate.scenes[index].snapshot = try candidate.scenes[index].snapshot
            .replacingGeneratedEnvironment(asset)
        try candidate.scenes[index].validate()
        do { try store.save(candidate) }
        catch {
            if let previousData {
                _ = try? EnvironmentAssetLibrary.storeSceneGeneratedEXR(
                    previousData, sceneID: sceneID,
                    libraryRoot: store.environmentLibraryRoot
                )
            } else {
                try? EnvironmentAssetLibrary.removeSceneGeneratedEXR(
                    sceneID: sceneID, libraryRoot: store.environmentLibraryRoot
                )
            }
            throw error
        }
        document = candidate
        return managed
    }

    @discardableResult
    func duplicate(_ scene: SavedScene) throws -> SavedScene {
        guard let store, document.scenes.contains(where: { $0.id == scene.id })
        else { throw SceneLibraryError.inaccessible("La escena ya no existe.") }
        let id = UUID()
        let asset: SavedSceneAsset?
        if let sourceAsset = scene.snapshot.generatedEnvironment,
           let source = try EnvironmentAssetLibrary.asset(
               sha256: sourceAsset.sha256, originalFileName: sourceAsset.fileName,
               libraryRoot: store.environmentLibraryRoot
           ) {
            let data = try Data(contentsOf: source.url, options: .mappedIfSafe)
            let copied = try EnvironmentAssetLibrary.storeSceneGeneratedEXR(
                data, sceneID: id, libraryRoot: store.environmentLibraryRoot
            )
            asset = .init(fileName: copied.originalFileName, sha256: copied.sha256)
        } else {
            asset = nil
        }
        let duplicate = SavedScene(
            id: id,
            name: "\(scene.name) copia",
            thumbnailFileName: "\(id.uuidString.lowercased()).png",
            snapshot: try scene.snapshot.replacingGeneratedEnvironment(asset)
        )
        try duplicate.validate()
        let thumbnail = try Data(contentsOf: store.thumbnailURL(for: scene))
        try store.writeThumbnail(thumbnail, for: duplicate)
        var candidate = document
        candidate.scenes.insert(duplicate, at: 0)
        do { try store.save(candidate) }
        catch {
            try? store.removeThumbnail(for: duplicate)
            if asset != nil {
                try? EnvironmentAssetLibrary.removeSceneGeneratedEXR(
                    sceneID: id, libraryRoot: store.environmentLibraryRoot
                )
            }
            throw error
        }
        document = candidate
        return duplicate
    }

    func delete(_ scene: SavedScene) throws {
        guard let store, document.scenes.contains(where: { $0.id == scene.id })
        else { throw SceneLibraryError.inaccessible("La escena ya no existe.") }
        let thumbnail = try Data(contentsOf: store.thumbnailURL(for: scene))
        let environment = try scene.snapshot.generatedEnvironment.flatMap {
            try EnvironmentAssetLibrary.asset(
                sha256: $0.sha256, originalFileName: $0.fileName,
                libraryRoot: store.environmentLibraryRoot
            ).map { try Data(contentsOf: $0.url, options: .mappedIfSafe) }
        }
        var candidate = document
        candidate.scenes.removeAll { $0.id == scene.id }
        try store.removeThumbnail(for: scene)
        if scene.snapshot.generatedEnvironment != nil {
            try EnvironmentAssetLibrary.removeSceneGeneratedEXR(
                sceneID: scene.id, libraryRoot: store.environmentLibraryRoot
            )
        }
        do { try store.save(candidate) }
        catch {
            try? store.writeThumbnail(thumbnail, for: scene)
            if let environment {
                _ = try? EnvironmentAssetLibrary.storeSceneGeneratedEXR(
                    environment, sceneID: scene.id,
                    libraryRoot: store.environmentLibraryRoot
                )
            }
            throw error
        }
        document = candidate
    }
}
