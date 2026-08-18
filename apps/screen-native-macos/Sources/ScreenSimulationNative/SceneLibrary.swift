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

/// An authored external dependency. Its absolute path is the sole identity; the user may
/// deliberately replace the file at that path without changing the saved scene.
struct SavedExternalAsset: Codable, Equatable, Sendable {
    let absolutePath: String

    var url: URL { URL(fileURLWithPath: absolutePath) }

    func validate() throws {
        guard absolutePath.hasPrefix("/"), !url.lastPathComponent.isEmpty else {
            throw SceneLibraryError.invalidDocument("Una ruta externa guardada no es válida.")
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
    enum Kind: String, Codable, Sendable { case syntheticPattern, externalMedia }
    let kind: Kind
    let patternRawValue: UInt32?
    let assets: [SavedExternalAsset]
    let missingMedia: SavedMissingMediaDescriptor?

    func validate() throws {
        switch kind {
        case .syntheticPattern:
            guard let patternRawValue, SyntheticPattern(rawValue: patternRawValue) != nil,
                  assets.isEmpty, missingMedia == nil else {
                throw SceneLibraryError.invalidDocument("La fuente sintética guardada no es válida.")
            }
        case .externalMedia:
            guard patternRawValue == nil, !assets.isEmpty, let missingMedia else {
                throw SceneLibraryError.invalidDocument("La escena no contiene sus medios fuente.")
            }
            try assets.forEach { try $0.validate() }
            try missingMedia.validate()
        }
    }
}

struct SavedTrackingCalibration: Codable, Equatable, Sendable {
    let unitValue: Double
    let unit: String
    let metersPerSourceUnit: Double

    func validate() throws {
        guard unitValue.isFinite, unitValue > 0, unit == "m" || unit == "cm",
              metersPerSourceUnit.isFinite, metersPerSourceUnit > 0 else {
            throw SceneLibraryError.invalidDocument("La calibración métrica del tracking no es válida.")
        }
    }
}

struct SavedTrackingScene: Codable, Equatable, Sendable {
    let absolutePath: String
    let cameraID: String
    let pointGroupID: String
    let visibleMeshIDs: [String]
    let pointsVisible: Bool
    let geometryVisible: Bool
    let cameraEnabled: Bool
    let calibration: SavedTrackingCalibration

    func validate() throws {
        try SavedExternalAsset(absolutePath: absolutePath).validate()
        guard !cameraID.isEmpty, !pointGroupID.isEmpty,
              Set(visibleMeshIDs).count == visibleMeshIDs.count else {
            throw SceneLibraryError.invalidDocument("La selección de tracking guardada no es válida.")
        }
        try calibration.validate()
    }
}

/// Scene persistence intentionally records authoring, not a resolved physical-profile snapshot.
/// The selected catalog IDs are resolved again when the scene opens, so a current device, camera
/// or lens definition remains the authority for its defaults and capabilities.
struct SceneAuthoringDocument: Codable, Equatable, Sendable {
    static let schema = "ScreenSimulation.SceneAuthoring.v2"

    let schema: String
    /// Catalog identities, not embedded profile snapshots. The live Global Library remains
    /// authoritative when the scene is reopened.
    let deviceProfileID: String
    let coverGlassProfileID: String
    let context: PhysicalSettingsExchange.FrameContext
    let model: PhysicalModelAuthoringState
    let environmentCalibration: EnvironmentAssetCalibration?

    init(
        deviceProfileID: String,
        coverGlassProfileID: String,
        context: PhysicalSettingsExchange.FrameContext,
        model: PhysicalModelAuthoringState,
        environmentCalibration: EnvironmentAssetCalibration?
    ) {
        schema = Self.schema
        self.deviceProfileID = deviceProfileID
        self.coverGlassProfileID = coverGlassProfileID
        self.context = context
        self.model = model
        self.environmentCalibration = environmentCalibration
    }

    func validate() throws {
        guard schema == Self.schema else {
            throw SceneLibraryError.invalidDocument("El documento de autoría de escena no es válido.")
        }
        guard !deviceProfileID.isEmpty, !coverGlassProfileID.isEmpty else {
            throw SceneLibraryError.invalidDocument("La escena no contiene las identidades de Device y Cover Glass.")
        }
    }
}

struct SavedSceneSnapshot: Codable, Equatable, Sendable {
    static let schema = "ScreenSimulation.SavedScene.v19"
    let schema: String
    let source: SavedSceneSource
    let currentFrame: Int
    let viewerZoom: Double
    let viewerPanX: Double
    let viewerPanY: Double
    let viewerIsFitted: Bool
    let authoring: SceneAuthoringDocument
    let generatedEnvironment: SavedSceneAsset?
    let tracking: SavedTrackingScene?

    private enum CodingKeys: String, CodingKey {
        case schema, source, currentFrame, viewerZoom, viewerPanX, viewerPanY
        case viewerIsFitted, authoring, generatedEnvironment, tracking
    }

    init(
        source: SavedSceneSource,
        currentFrame: Int,
        viewerZoom: Double,
        viewerPanX: Double,
        viewerPanY: Double,
        viewerIsFitted: Bool,
        authoring: SceneAuthoringDocument,
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
        self.authoring = authoring
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
        authoring = try values.decode(SceneAuthoringDocument.self, forKey: .authoring)
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
        try values.encode(authoring, forKey: .authoring)
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
              authoring.schema == SceneAuthoringDocument.schema
        else { throw SceneLibraryError.invalidDocument("El snapshot de escena no es válido.") }
        try source.validate()
        try authoring.validate()
        try generatedEnvironment?.validate()
        try tracking?.validate()
    }

    func replacingGeneratedEnvironment(
        _ asset: SavedSceneAsset?, absolutePath: String? = nil
    ) throws -> Self {
        guard let asset else {
            return Self(
                source: source, currentFrame: currentFrame, viewerZoom: viewerZoom,
                viewerPanX: viewerPanX, viewerPanY: viewerPanY,
                viewerIsFitted: viewerIsFitted, authoring: authoring,
                generatedEnvironment: nil,
                tracking: tracking
            )
        }
        guard let resolvedAbsolutePath = absolutePath
            ?? authoring.context.environmentResource.absolutePath,
            resolvedAbsolutePath.hasPrefix("/")
        else {
            throw SceneLibraryError.invalidDocument("Falta la ruta del entorno generado.")
        }
        let previous = authoring.context
        let context = PhysicalSettingsExchange.FrameContext(
            selection: previous.selection,
            sourceInputTransformID: previous.sourceInputTransformID,
            sourceAlphaMode: previous.sourceAlphaMode,
            sourceColorModel: previous.sourceColorModel,
            sourceYUVMatrix: previous.sourceYUVMatrix,
            sourceSignalRange: previous.sourceSignalRange,
            sourcePlacementID: previous.sourcePlacementID,
            previewOutputTransformID: previous.previewOutputTransformID,
            previewPhaseID: previous.previewPhaseID,
            environmentResource: .init(
                kind: .image, fileName: asset.fileName,
                absolutePath: resolvedAbsolutePath, inputTransformID: "acescg"
            ),
            referenceResource: previous.referenceResource
        )
        return Self(
            source: source, currentFrame: currentFrame, viewerZoom: viewerZoom,
            viewerPanX: viewerPanX, viewerPanY: viewerPanY,
            viewerIsFitted: viewerIsFitted,
            authoring: .init(
                deviceProfileID: authoring.deviceProfileID,
                coverGlassProfileID: authoring.coverGlassProfileID,
                context: context, model: authoring.model,
                environmentCalibration: authoring.environmentCalibration
            ),
            generatedEnvironment: asset, tracking: tracking
        )
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

/// A self-contained recovery point. External resources intentionally remain external paths;
/// only app-generated HDRI bytes are retained because their scene-owned file may be replaced.
struct SceneAutosaveRevision: Codable, Equatable, Identifiable, Sendable {
    static let schema = "ScreenSimulation.SceneAutosave.v1"
    let schema: String
    let id: UUID
    let originalSceneID: UUID
    let sceneName: String
    let savedAt: Date
    let snapshot: SavedSceneSnapshot
    let thumbnailFileName: String
    let generatedEnvironmentFileName: String?

    init(
        id: UUID = UUID(), originalSceneID: UUID, sceneName: String,
        savedAt: Date = Date(), snapshot: SavedSceneSnapshot,
        hasGeneratedEnvironment: Bool
    ) {
        schema = Self.schema
        self.id = id
        self.originalSceneID = originalSceneID
        self.sceneName = sceneName
        self.savedAt = savedAt
        self.snapshot = snapshot
        thumbnailFileName = "\(id.uuidString.lowercased()).png"
        generatedEnvironmentFileName = hasGeneratedEnvironment
            ? "\(id.uuidString.lowercased()).exr" : nil
    }

    func validate() throws {
        guard schema == Self.schema,
              !sceneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              savedAt.timeIntervalSinceReferenceDate.isFinite,
              thumbnailFileName == "\(id.uuidString.lowercased()).png",
              generatedEnvironmentFileName == nil
                || generatedEnvironmentFileName == "\(id.uuidString.lowercased()).exr"
        else { throw SceneLibraryError.invalidDocument("La copia de recuperación no es válida.") }
        try snapshot.validate()
    }
}

struct SceneAutosaveHistoryTarget: Identifiable, Sendable {
    let sceneID: UUID
    let sceneName: String
    let isDeletedScene: Bool
    var id: UUID { sceneID }
}

struct SceneLibraryDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 19
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
        documentURL = directory.appendingPathComponent("Scenes.v19.json")
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
                guard FileManager.default.fileExists(atPath: tracking.absolutePath) else {
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

    func autosaveDirectory(for sceneID: UUID) -> URL {
        directoryURL.deletingLastPathComponent()
            .appendingPathComponent("Autosave.v19", isDirectory: true)
            .appendingPathComponent(sceneID.uuidString.lowercased(), isDirectory: true)
    }

    func writeAutosave(
        scene: SavedScene,
        thumbnailPNG: Data,
        generatedEnvironmentEXR: Data?
    ) throws -> SceneAutosaveRevision {
        guard !thumbnailPNG.isEmpty else {
            throw SceneLibraryError.invalidDocument("La miniatura de recuperación está vacía.")
        }
        let directory = autosaveDirectory(for: scene.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let revision = SceneAutosaveRevision(
            originalSceneID: scene.id, sceneName: scene.name, snapshot: scene.snapshot,
            hasGeneratedEnvironment: generatedEnvironmentEXR != nil
        )
        try revision.validate()
        try thumbnailPNG.write(
            to: directory.appendingPathComponent(revision.thumbnailFileName), options: .atomic
        )
        if let generatedEnvironmentEXR {
            try generatedEnvironmentEXR.write(
                to: directory.appendingPathComponent(
                    try requiredGeneratedEnvironmentFileName(revision)
                ), options: .atomic
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(revision).write(
                to: directory.appendingPathComponent("\(revision.id.uuidString.lowercased()).json"),
                options: .atomic
            )
        } catch {
            try? FileManager.default.removeItem(
                at: directory.appendingPathComponent(revision.thumbnailFileName)
            )
            if let fileName = revision.generatedEnvironmentFileName {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(fileName))
            }
            throw error
        }
        return revision
    }

    func autosaves(for sceneID: UUID) throws -> [SceneAutosaveRevision] {
        let directory = autosaveDirectory(for: sceneID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { $0.pathExtension == "json" }
        let revisions = try urls.map { url -> SceneAutosaveRevision in
            let data = try Data(contentsOf: url)
            let revision = try JSONDecoder().decode(SceneAutosaveRevision.self, from: data)
            try revision.validate()
            guard revision.originalSceneID == sceneID,
                  FileManager.default.fileExists(
                      atPath: directory.appendingPathComponent(revision.thumbnailFileName).path
                  ),
                  revision.generatedEnvironmentFileName.map({
                      FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path)
                  }) ?? true
            else { throw SceneLibraryError.invalidDocument("La copia de recuperación está incompleta.") }
            return revision
        }
        return revisions.sorted { $0.savedAt > $1.savedAt }
    }

    func autosaveThumbnailURL(_ revision: SceneAutosaveRevision) -> URL {
        autosaveDirectory(for: revision.originalSceneID).appendingPathComponent(revision.thumbnailFileName)
    }

    func autosaveGeneratedEnvironmentEXR(_ revision: SceneAutosaveRevision) throws -> Data? {
        guard let fileName = revision.generatedEnvironmentFileName else { return nil }
        return try Data(contentsOf: autosaveDirectory(for: revision.originalSceneID)
            .appendingPathComponent(fileName), options: .mappedIfSafe)
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
                      "viewerPanY", "viewerIsFitted", "authoring",
                      "generatedEnvironment", "tracking",
                  ],
                  let source = snapshot["source"] as? [String: Any],
                  Set(source.keys) == ["kind", "assets", "missingMedia"]
                    || Set(source.keys) == ["kind", "patternRawValue", "assets"],
                  let assets = source["assets"] as? [[String: Any]],
                  assets.allSatisfy({ Set($0.keys) == ["absolutePath"] }),
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
                                "absolutePath", "cameraID", "pointGroupID", "visibleMeshIDs",
                                "pointsVisible", "geometryVisible", "cameraEnabled", "calibration",
                            ],
                            let calibration = tracking["calibration"] as? [String: Any],
                            Set(calibration.keys) == [
                                "unitValue", "unit", "metersPerSourceUnit",
                            ] else { return false }
                      return true
                  }())
            else { throw SceneLibraryError.invalidDocument("La escena contiene campos desconocidos.") }
        }
    }
}

private func requiredGeneratedEnvironmentFileName(
    _ revision: SceneAutosaveRevision
) throws -> String {
    guard let fileName = revision.generatedEnvironmentFileName else {
        throw SceneLibraryError.invalidDocument("La copia de recuperación no contiene entorno generado.")
    }
    return fileName
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
    private final class UndoManagerBox: @unchecked Sendable {
        weak var value: UndoManager?
        init(_ value: UndoManager?) { self.value = value }
    }

    private struct StoredUpdate {
        let snapshot: SavedSceneSnapshot
        let thumbnailPNG: Data
        let generatedEnvironmentEXR: Data?

        var capture: SavedSceneCapture {
            SavedSceneCapture(
                snapshot: snapshot,
                thumbnailPNG: thumbnailPNG,
                generatedEnvironmentEXR: generatedEnvironmentEXR
            )
        }
    }

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

    func autosaveHistoryTarget(for scene: SavedScene) -> SceneAutosaveHistoryTarget {
        .init(sceneID: scene.id, sceneName: scene.name, isDeletedScene: false)
    }

    func deletedAutosaveHistoryTargets() throws -> [SceneAutosaveHistoryTarget] {
        guard let store else { throw SceneLibraryError.inaccessible("Sin destino de escenas.") }
        let root = store.directoryURL.deletingLastPathComponent()
            .appendingPathComponent("Autosave.v19", isDirectory: true)
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ).compactMap { directory -> SceneAutosaveHistoryTarget? in
            guard let id = UUID(uuidString: directory.lastPathComponent),
                  !document.scenes.contains(where: { $0.id == id }),
                  let revision = try store.autosaves(for: id).first
            else { return nil }
            return .init(sceneID: id, sceneName: revision.sceneName, isDeletedScene: true)
        }.sorted { $0.sceneName.localizedStandardCompare($1.sceneName) == .orderedAscending }
    }

    func autosaves(for target: SceneAutosaveHistoryTarget) throws -> [SceneAutosaveRevision] {
        guard let store else { throw SceneLibraryError.inaccessible("Sin destino de escenas.") }
        return try store.autosaves(for: target.sceneID)
    }

    func autosaveThumbnailURL(for revision: SceneAutosaveRevision) -> URL? {
        store?.autosaveThumbnailURL(revision)
    }

    @discardableResult
    func restoreAutosave(_ revision: SceneAutosaveRevision) throws -> SavedScene {
        guard let store else { throw SceneLibraryError.inaccessible("Sin destino de escenas.") }
        let thumbnail = try Data(contentsOf: store.autosaveThumbnailURL(revision))
        let generatedEnvironment = try store.autosaveGeneratedEnvironmentEXR(revision)
        return try add(
            capture: .init(
                snapshot: revision.snapshot, thumbnailPNG: thumbnail,
                generatedEnvironmentEXR: generatedEnvironment
            ),
            name: "\(revision.sceneName) recuperada"
        )
    }

    @discardableResult
    func add(capture: SavedSceneCapture, name: String? = nil) throws -> SavedScene {
        guard let store else { throw SceneLibraryError.inaccessible("Sin destino de escenas.") }
        let id = UUID()
        let generated = try capture.generatedEnvironmentEXR.map {
            let managed = try EnvironmentAssetLibrary.storeSceneGeneratedEXR(
                $0, sceneID: id, libraryRoot: store.environmentLibraryRoot
            )
            return (SavedSceneAsset(fileName: managed.originalFileName, sha256: managed.sha256), managed.url.path)
        }
        let snapshot = try capture.snapshot.replacingGeneratedEnvironment(generated?.0, absolutePath: generated?.1)
        let scene = SavedScene(
            id: id,
            name: name ?? "Escena \(document.scenes.count + 1)",
            thumbnailFileName: "\(id.uuidString.lowercased()).png",
            snapshot: snapshot
        )
        try scene.validate()
        _ = try store.writeAutosave(
            scene: scene, thumbnailPNG: capture.thumbnailPNG,
            generatedEnvironmentEXR: capture.generatedEnvironmentEXR
        )
        try store.writeThumbnail(capture.thumbnailPNG, for: scene)
        var candidate = document
        candidate.scenes.insert(scene, at: 0)
        do {
            try store.save(candidate)
            document = candidate
            return scene
        } catch {
            try? store.removeThumbnail(for: scene)
            if generated != nil {
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

    func update(
        _ scene: SavedScene,
        capture: SavedSceneCapture,
        undoManager: UndoManager? = nil
    ) throws {
        let prior = try storedUpdate(sceneID: scene.id)
        try applyUpdate(sceneID: scene.id, capture: capture)
        registerUpdateUndo(sceneID: scene.id, state: prior, undoManager: undoManager)
    }

    private func storedUpdate(sceneID: UUID) throws -> StoredUpdate {
        guard let store,
              let scene = document.scenes.first(where: { $0.id == sceneID })
        else { throw SceneLibraryError.inaccessible("La escena ya no existe.") }
        let environment = try scene.snapshot.generatedEnvironment.flatMap {
            try EnvironmentAssetLibrary.asset(
                sha256: $0.sha256, originalFileName: $0.fileName,
                libraryRoot: store.environmentLibraryRoot
            ).map { try Data(contentsOf: $0.url, options: .mappedIfSafe) }
        }
        return try StoredUpdate(
            snapshot: scene.snapshot,
            thumbnailPNG: Data(contentsOf: store.thumbnailURL(for: scene)),
            generatedEnvironmentEXR: environment
        )
    }

    private func applyUpdate(sceneID: UUID, capture: SavedSceneCapture) throws {
        guard let store, let index = document.scenes.firstIndex(where: { $0.id == sceneID })
        else { throw SceneLibraryError.inaccessible("La escena ya no existe.") }
        let scene = document.scenes[index]
        var candidate = document
        let previousAsset = scene.snapshot.generatedEnvironment
        let previousEnvironmentData = try previousAsset.flatMap {
            try EnvironmentAssetLibrary.asset(
                sha256: $0.sha256, originalFileName: $0.fileName,
                libraryRoot: store.environmentLibraryRoot
            ).map { try Data(contentsOf: $0.url, options: .mappedIfSafe) }
        }
        let generated = try capture.generatedEnvironmentEXR.map {
            let managed = try EnvironmentAssetLibrary.storeSceneGeneratedEXR(
                $0, sceneID: scene.id, libraryRoot: store.environmentLibraryRoot
            )
            return (SavedSceneAsset(fileName: managed.originalFileName, sha256: managed.sha256), managed.url.path)
        }
        candidate.scenes[index].snapshot = try capture.snapshot.replacingGeneratedEnvironment(generated?.0, absolutePath: generated?.1)
        try candidate.scenes[index].validate()
        _ = try store.writeAutosave(
            scene: candidate.scenes[index], thumbnailPNG: capture.thumbnailPNG,
            generatedEnvironmentEXR: capture.generatedEnvironmentEXR
        )
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
            } else if generated != nil {
                try? EnvironmentAssetLibrary.removeSceneGeneratedEXR(
                    sceneID: scene.id, libraryRoot: store.environmentLibraryRoot
                )
            }
            throw error
        }
        if previousAsset != nil, generated == nil {
            try EnvironmentAssetLibrary.removeSceneGeneratedEXR(
                sceneID: scene.id, libraryRoot: store.environmentLibraryRoot
            )
        }
        document = candidate
    }

    private func registerUpdateUndo(
        sceneID: UUID,
        state: StoredUpdate,
        undoManager: UndoManager?
    ) {
        guard let undoManager else { return }
        let manager = UndoManagerBox(undoManager)
        undoManager.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.restoreUpdate(
                    sceneID: sceneID,
                    state: state,
                    undoManager: manager.value
                )
            }
        }
        undoManager.setActionName("Actualizar escena")
    }

    private func restoreUpdate(
        sceneID: UUID,
        state: StoredUpdate,
        undoManager: UndoManager?
    ) {
        do {
            let inverse = try storedUpdate(sceneID: sceneID)
            try applyUpdate(sceneID: sceneID, capture: state.capture)
            registerUpdateUndo(sceneID: sceneID, state: inverse, undoManager: undoManager)
        } catch {
            blockedError = "No se pudo restaurar ‘Actualizar escena’: \(error.localizedDescription)"
        }
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
            .replacingGeneratedEnvironment(asset, absolutePath: managed.url.path)
        try candidate.scenes[index].validate()
        _ = try store.writeAutosave(
            scene: candidate.scenes[index],
            thumbnailPNG: Data(contentsOf: store.thumbnailURL(for: candidate.scenes[index])),
            generatedEnvironmentEXR: data
        )
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
        let copiedAbsolutePath: String?
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
            copiedAbsolutePath = copied.url.path
        } else {
            asset = nil
            copiedAbsolutePath = nil
        }
        let duplicate = SavedScene(
            id: id,
            name: "\(scene.name) copia",
            thumbnailFileName: "\(id.uuidString.lowercased()).png",
            snapshot: try scene.snapshot.replacingGeneratedEnvironment(
                asset, absolutePath: copiedAbsolutePath
            )
        )
        try duplicate.validate()
        let thumbnail = try Data(contentsOf: store.thumbnailURL(for: scene))
        _ = try store.writeAutosave(
            scene: duplicate, thumbnailPNG: thumbnail,
            generatedEnvironmentEXR: asset.flatMap { copiedAsset in
                try? EnvironmentAssetLibrary.asset(
                    sha256: copiedAsset.sha256, originalFileName: copiedAsset.fileName,
                    libraryRoot: store.environmentLibraryRoot
                ).flatMap { try? Data(contentsOf: $0.url, options: .mappedIfSafe) }
            } ?? nil
        )
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
        _ = try store.writeAutosave(
            scene: scene, thumbnailPNG: thumbnail, generatedEnvironmentEXR: environment
        )
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
