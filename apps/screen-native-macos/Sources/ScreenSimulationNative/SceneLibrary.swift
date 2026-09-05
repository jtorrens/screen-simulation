import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import ScreenSimulationPresentation
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
    let scene: TrackingScene
    let cameraID: String
    let pointGroupID: String
    let visibleMeshIDs: [String]
    let pointsVisible: Bool
    let geometryVisible: Bool
    let cameraEnabled: Bool
    let calibration: SavedTrackingCalibration

    func validate() throws {
        try scene.validate()
        guard !cameraID.isEmpty, !pointGroupID.isEmpty,
              Set(visibleMeshIDs).count == visibleMeshIDs.count else {
            throw SceneLibraryError.invalidDocument("La selección de tracking guardada no es válida.")
        }
        try calibration.validate()
    }
}

/// Scene persistence records selected profile identities plus authored overrides and tracks.
/// Current internal profile definitions remain authoritative for values without an override.
struct SceneProfileSelection: Codable, Equatable, Sendable {
    let deviceID: String
    let coverGlassID: String
    let captureID: String
    let lensID: String
    let environmentID: String
    let deliveryID: String
    let recordingID: String

    func validate() throws {
        guard [deviceID, coverGlassID, captureID, lensID, environmentID, deliveryID, recordingID]
            .allSatisfy({ !$0.isEmpty })
        else {
            throw SceneLibraryError.invalidDocument(
                "La escena contiene una identidad de perfil vacía."
            )
        }
    }
}

struct SceneControlOverride: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case choice, scalar, toggle }

    let controlID: String
    let kind: Kind
    let choice: String?
    let scalar: Double?
    let toggle: Bool?

    static func choice(_ controlID: String, _ value: String) -> Self {
        .init(controlID: controlID, kind: .choice, choice: value, scalar: nil, toggle: nil)
    }

    static func scalar(_ controlID: String, _ value: Double) -> Self {
        .init(controlID: controlID, kind: .scalar, choice: nil, scalar: value, toggle: nil)
    }

    static func toggle(_ controlID: String, _ value: Bool) -> Self {
        .init(controlID: controlID, kind: .toggle, choice: nil, scalar: nil, toggle: value)
    }

    var intent: TestControlIntent {
        switch kind {
        case .choice: .setChoice(controlID: controlID, optionID: choice!)
        case .scalar: .setScalar(controlID: controlID, value: scalar!)
        case .toggle: .setToggle(controlID: controlID, value: toggle!)
        }
    }

    func validate() throws {
        guard !controlID.isEmpty else {
            throw SceneLibraryError.invalidDocument("Un override no tiene identidad de control.")
        }
        switch kind {
        case .choice:
            guard let choice, !choice.isEmpty, scalar == nil, toggle == nil else {
                throw SceneLibraryError.invalidDocument("Un override Choice no es válido.")
            }
        case .scalar:
            guard let scalar, scalar.isFinite, choice == nil, toggle == nil else {
                throw SceneLibraryError.invalidDocument("Un override Scalar no es válido.")
            }
        case .toggle:
            guard toggle != nil, choice == nil, scalar == nil else {
                throw SceneLibraryError.invalidDocument("Un override Toggle no es válido.")
            }
        }
    }
}

struct SceneModelOverrides: Codable, Equatable, Sendable {
    let screen: PhysicalModelAuthoringState.ContinuousValue?
    let stages: [PhysicalModelAuthoringState.Stage]

    func validate() throws {
        guard Set(stages.map(\.stableID)).count == stages.count else {
            throw SceneLibraryError.invalidDocument("Hay overrides de etapa duplicados.")
        }
        if let screen {
            guard screen.storedAmount.isFinite else {
                throw SceneLibraryError.invalidDocument("El override general de pantalla no es válido.")
            }
        }
    }
}

struct SceneAuthoringContext: Codable, Equatable, Sendable {
    let sourceInputTransformID: String
    let sourceAlphaMode: String
    let sourceColorModel: String
    let sourceYUVMatrix: String
    let sourceSignalRange: String
    let sourcePlacementID: String
    let previewOutputTransformID: String
    let previewPhaseID: String
    let referencePlateID: String
    let environmentResource: PhysicalSettingsExchange.EnvironmentResource
    let referenceResource: PhysicalSettingsExchange.ReferenceResource

    func validate() throws {
        guard ["video-reference", "vfx-checker", "black", "white", "middle-gray"]
            .contains(referencePlateID)
        else { throw SceneLibraryError.invalidDocument("La placa de referencia no es válida.") }
        try environmentResource.validate()
        try referenceResource.validate()
        guard referencePlateID != "video-reference" || referenceResource.kind == .imageOrVideo
        else { throw SceneLibraryError.invalidDocument("La placa de vídeo requiere una referencia.") }
    }
}

struct SceneAuthoringDocument: Codable, Equatable, Sendable {
    static let schema = "ScreenSimulation.SceneAuthoring.v4"

    let schema: String
    let profiles: SceneProfileSelection
    let overrides: [SceneControlOverride]
    let modelOverrides: SceneModelOverrides
    let context: SceneAuthoringContext
    let environmentCalibration: EnvironmentAssetCalibration?

    init(
        profiles: SceneProfileSelection,
        overrides: [SceneControlOverride],
        modelOverrides: SceneModelOverrides,
        context: SceneAuthoringContext,
        environmentCalibration: EnvironmentAssetCalibration?
    ) {
        schema = Self.schema
        self.profiles = profiles
        self.overrides = overrides
        self.modelOverrides = modelOverrides
        self.context = context
        self.environmentCalibration = environmentCalibration
    }

    func validate() throws {
        guard schema == Self.schema else {
            throw SceneLibraryError.invalidDocument("El documento de autoría de escena no es válido.")
        }
        try profiles.validate()
        guard Set(overrides.map(\.controlID)).count == overrides.count else {
            throw SceneLibraryError.invalidDocument("Hay overrides de control duplicados.")
        }
        try overrides.forEach { try $0.validate() }
        try modelOverrides.validate()
        try context.validate()
    }
}

struct SavedSceneSnapshot: Codable, Equatable, Sendable {
    static let schema = "ScreenSimulation.SavedScene.v26"
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
    let fusionTrackerMotion: FusionTrackerPoseTrack?
    let trackingSceneMethod: TrackingSceneMethod
    var animation: SceneAnimationDocument

    private enum CodingKeys: String, CodingKey {
        case schema, source, currentFrame, viewerZoom, viewerPanX, viewerPanY
        case viewerIsFitted, authoring, generatedEnvironment, tracking, fusionTrackerMotion
        case trackingSceneMethod
        case animation
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
        tracking: SavedTrackingScene? = nil,
        fusionTrackerMotion: FusionTrackerPoseTrack? = nil,
        trackingSceneMethod: TrackingSceneMethod,
        animation: SceneAnimationDocument = .init()
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
        self.fusionTrackerMotion = fusionTrackerMotion
        self.trackingSceneMethod = trackingSceneMethod
        self.animation = animation
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
        fusionTrackerMotion = try values.decodeIfPresent(
            FusionTrackerPoseTrack.self, forKey: .fusionTrackerMotion
        )
        trackingSceneMethod = try values.decode(
            TrackingSceneMethod.self, forKey: .trackingSceneMethod
        )
        animation = try values.decode(SceneAnimationDocument.self, forKey: .animation)
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
        if let fusionTrackerMotion {
            try values.encode(fusionTrackerMotion, forKey: .fusionTrackerMotion)
        } else {
            try values.encodeNil(forKey: .fusionTrackerMotion)
        }
        try values.encode(trackingSceneMethod, forKey: .trackingSceneMethod)
        try values.encode(animation, forKey: .animation)
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
        try fusionTrackerMotion?.validate()
        try animation.validate()
    }

    static func hasStrictTopLevelShape(_ snapshot: [String: Any]) -> Bool {
        guard Set(snapshot.keys) == [
            "schema", "source", "currentFrame", "viewerZoom", "viewerPanX",
            "viewerPanY", "viewerIsFitted", "authoring", "generatedEnvironment",
            "tracking", "fusionTrackerMotion", "trackingSceneMethod", "animation",
        ], let animation = snapshot["animation"] else { return false }
        return SceneAnimationDocument.hasStrictShape(animation)
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
                tracking: tracking, fusionTrackerMotion: fusionTrackerMotion,
                trackingSceneMethod: trackingSceneMethod, animation: animation
            )
        }
        guard let resolvedAbsolutePath = absolutePath
            ?? authoring.context.environmentResource.absolutePath,
            resolvedAbsolutePath.hasPrefix("/")
        else {
            throw SceneLibraryError.invalidDocument("Falta la ruta del entorno generado.")
        }
        let previous = authoring.context
        let context = SceneAuthoringContext(
            sourceInputTransformID: previous.sourceInputTransformID,
            sourceAlphaMode: previous.sourceAlphaMode,
            sourceColorModel: previous.sourceColorModel,
            sourceYUVMatrix: previous.sourceYUVMatrix,
            sourceSignalRange: previous.sourceSignalRange,
            sourcePlacementID: previous.sourcePlacementID,
            previewOutputTransformID: previous.previewOutputTransformID,
            previewPhaseID: previous.previewPhaseID,
            referencePlateID: previous.referencePlateID,
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
                profiles: authoring.profiles,
                overrides: authoring.overrides,
                modelOverrides: authoring.modelOverrides,
                context: context,
                environmentCalibration: authoring.environmentCalibration
            ),
            generatedEnvironment: asset, tracking: tracking,
            fusionTrackerMotion: fusionTrackerMotion,
            trackingSceneMethod: trackingSceneMethod, animation: animation
        )
    }

    func removingImported3D() -> Self {
        Self(
            source: source, currentFrame: currentFrame, viewerZoom: viewerZoom,
            viewerPanX: viewerPanX, viewerPanY: viewerPanY,
            viewerIsFitted: viewerIsFitted, authoring: authoring,
            generatedEnvironment: generatedEnvironment, tracking: nil,
            fusionTrackerMotion: fusionTrackerMotion,
            trackingSceneMethod: trackingSceneMethod, animation: animation
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

enum SceneSettingsPasteDestination: Sendable {
    case storedScene
    case activeScene(SavedSceneCapture)
}

enum SceneDefaultResetDestination: Sendable {
    case storedScene
    case activeScene(SavedSceneCapture)
}

enum SceneImported3DRemovalDestination: Sendable {
    case storedScene
    case activeScene(SavedSceneCapture)
}

/// A self-contained recovery point. Only source, reference and authored external HDRI media
/// remain external paths; imported 3D authoring is embedded. App-generated HDRI bytes are
/// retained because their scene-owned file may be replaced.
struct SceneAutosaveRevision: Codable, Equatable, Identifiable, Sendable {
    static let schema = "ScreenSimulation.SceneAutosave.v3"
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

enum SceneBranchAssociationState: String, Codable, Equatable, Sendable {
    case free
    case associated
}

struct ScenePlacement: Codable, Equatable, Identifiable, Sendable {
    let sceneID: UUID
    let ordinal: Int
    var id: UUID { sceneID }
}

struct SceneShot: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var associationState: SceneBranchAssociationState
    var externalReference: ShotManagerShotReference?
    var nextSceneOrdinal: Int
    var scenes: [ScenePlacement]

    init(id: UUID = UUID(), name: String, externalReference: ShotManagerShotReference? = nil) {
        self.id = id
        self.name = name
        associationState = externalReference == nil ? .free : .associated
        self.externalReference = externalReference
        nextSceneOrdinal = 1
        scenes = []
    }
}

struct SceneEpisode: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var associationState: SceneBranchAssociationState
    var externalReference: ShotManagerEpisodeReference?
    var shots: [SceneShot]

    init(id: UUID = UUID(), name: String, externalReference: ShotManagerEpisodeReference? = nil) {
        self.id = id
        self.name = name
        associationState = externalReference == nil ? .free : .associated
        self.externalReference = externalReference
        shots = []
    }
}

struct SceneProduction: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var seasonSlug: String
    var association: ShotManagerProductionAssociation?
    var episodes: [SceneEpisode]

    init(
        id: UUID = UUID(), name: String, seasonSlug: String = "",
        association: ShotManagerProductionAssociation? = nil
    ) {
        self.id = id
        self.name = name
        self.seasonSlug = seasonSlug
        self.association = association
        episodes = []
    }
}

struct SceneLibraryDocument: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 28
    let schemaVersion: Int
    var scenes: [SavedScene]
    var productions: [SceneProduction]
    var unclassifiedSceneIDs: [UUID]

    init(
        scenes: [SavedScene] = [], productions: [SceneProduction] = [],
        unclassifiedSceneIDs: [UUID]? = nil
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.scenes = scenes
        self.productions = productions
        self.unclassifiedSceneIDs = unclassifiedSceneIDs ?? scenes.map(\.id)
    }

    func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SceneLibraryError.unsupportedSchema(schemaVersion)
        }
        guard Set(scenes.map(\.id)).count == scenes.count else {
            throw SceneLibraryError.invalidDocument("Hay identidades de escena duplicadas.")
        }
        try scenes.forEach { try $0.validate() }
        guard Set(productions.map(\.id)).count == productions.count,
              Set(unclassifiedSceneIDs).count == unclassifiedSceneIDs.count else {
            throw SceneLibraryError.invalidDocument("Hay identidades jerárquicas duplicadas.")
        }
        let sceneIDs = Set(scenes.map(\.id))
        var placements = unclassifiedSceneIDs
        for production in productions {
            guard !production.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SceneLibraryError.invalidDocument("La Producción necesita nombre.")
            }
            try production.association?.validate()
            guard Set(production.episodes.map(\.id)).count == production.episodes.count else {
                throw SceneLibraryError.invalidDocument("Hay Episodios locales duplicados.")
            }
            var activeEpisodeIDs = Set<String>()
            for episode in production.episodes {
                guard !episode.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      episode.associationState != .associated || episode.externalReference != nil,
                      Set(episode.shots.map(\.id)).count == episode.shots.count else {
                    throw SceneLibraryError.invalidDocument("El Episodio local no es válido.")
                }
                if let reference = episode.externalReference {
                    try reference.validate()
                    guard episode.associationState != .associated || (
                        production.association?.productionId == reference.productionId
                        && activeEpisodeIDs.insert(reference.episodeId).inserted
                    ) else {
                        throw SceneLibraryError.invalidDocument("La asociación de Episodio no pertenece a su Producción.")
                    }
                }
                var activeShotIDs = Set<String>()
                for shot in episode.shots {
                    guard !shot.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          shot.associationState != .associated || shot.externalReference != nil,
                          (1...1000).contains(shot.nextSceneOrdinal),
                          Set(shot.scenes.map(\.sceneID)).count == shot.scenes.count,
                          Set(shot.scenes.map(\.ordinal)).count == shot.scenes.count,
                          shot.scenes.allSatisfy({ (1...999).contains($0.ordinal) && $0.ordinal < shot.nextSceneOrdinal }) else {
                        throw SceneLibraryError.invalidDocument("El Plano local o sus ordinales no son válidos.")
                    }
                    if let reference = shot.externalReference {
                        try reference.validate()
                        guard shot.associationState != .associated || (
                            episode.associationState == .associated
                            && episode.externalReference != nil
                            && production.association?.productionId == reference.productionId
                            && activeShotIDs.insert(reference.shotId).inserted
                        ) else {
                            throw SceneLibraryError.invalidDocument("La asociación de Plano no pertenece a su Episodio.")
                        }
                    }
                    placements.append(contentsOf: shot.scenes.map(\.sceneID))
                }
            }
        }
        guard Set(placements) == sceneIDs, placements.count == sceneIDs.count else {
            throw SceneLibraryError.invalidDocument("Cada escena debe pertenecer exactamente a un Plano o a Sin clasificar.")
        }
    }
}

private extension SceneLibraryDocument {
    mutating func renameScene(_ sceneID: UUID, for shotName: String, ordinal: Int) {
        guard let sceneIndex = scenes.firstIndex(where: { $0.id == sceneID }) else { return }
        scenes[sceneIndex].name = "\(shotName)_\(String(format: "%03d", ordinal))"
    }

    mutating func renamePlacedScenes(for shot: SceneShot) {
        for placement in shot.scenes {
            renameScene(placement.sceneID, for: shot.name, ordinal: placement.ordinal)
        }
    }

    func episodeLocation(id: UUID) -> (production: Int, episode: Int)? {
        for production in productions.indices {
            if let episode = productions[production].episodes.firstIndex(where: { $0.id == id }) {
                return (production, episode)
            }
        }
        return nil
    }

    func shotLocation(id: UUID) -> (production: Int, episode: Int, shot: Int)? {
        for production in productions.indices {
            for episode in productions[production].episodes.indices {
                if let shot = productions[production].episodes[episode].shots.firstIndex(where: { $0.id == id }) {
                    return (production, episode, shot)
                }
            }
        }
        return nil
    }

    func shotContaining(sceneID: UUID) -> (
        production: SceneProduction, episode: SceneEpisode, shot: SceneShot
    )? {
        for production in productions {
            for episode in production.episodes {
                if let shot = episode.shots.first(where: { $0.scenes.contains(where: { $0.sceneID == sceneID }) }) {
                    return (production, episode, shot)
                }
            }
        }
        return nil
    }

    mutating func freeAllReferences(productionIndex: Int) {
        for episode in productions[productionIndex].episodes.indices {
            productions[productionIndex].episodes[episode].associationState = .free
            for shot in productions[productionIndex].episodes[episode].shots.indices {
                productions[productionIndex].episodes[episode].shots[shot].associationState = .free
            }
        }
    }

    mutating func refreshReferences(
        productionIndex: Int, from projection: ShotManagerProductionProjection
    ) {
        let productionID = projection.productionId
        for episodeIndex in productions[productionIndex].episodes.indices {
            var episode = productions[productionIndex].episodes[episodeIndex]
            if let prior = episode.externalReference,
               prior.productionId == productionID,
               let current = projection.episodes.first(where: { $0.id == prior.episodeId }) {
                episode.externalReference = .init(
                    productionId: productionID, episodeId: current.id,
                    episodeOrder: current.order, episodeSlug: current.slug,
                    episodePathSegments: current.pathSegments
                )
                episode.associationState = .associated
                episode.name = current.slug
            } else {
                episode.associationState = .free
            }
            for shotIndex in episode.shots.indices {
                guard episode.associationState == .associated,
                      let episodeID = episode.externalReference?.episodeId,
                      let prior = episode.shots[shotIndex].externalReference,
                      prior.productionId == productionID,
                      let current = projection.shots.first(where: {
                          $0.id == prior.shotId && $0.episodeId == episodeID
                      }) else {
                    episode.shots[shotIndex].associationState = .free
                    continue
                }
                episode.shots[shotIndex].externalReference = .init(
                    productionId: productionID, shotId: current.id,
                    canonicalName: current.canonicalName
                )
                episode.shots[shotIndex].associationState = .associated
                episode.shots[shotIndex].name = current.canonicalName
                renamePlacedScenes(for: episode.shots[shotIndex])
            }
            productions[productionIndex].episodes[episodeIndex] = episode
        }
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

    init(
        directoryURL: URL? = nil,
        environmentLibraryRoot: URL? = nil
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
        documentURL = directory.appendingPathComponent("Scenes.v28.json")
    }

    func load() throws -> SceneLibraryDocument {
        guard FileManager.default.fileExists(atPath: documentURL.path) else {
            let prior = directoryURL.appendingPathComponent("Scenes.v27.json")
            if FileManager.default.fileExists(atPath: prior.path) {
                throw SceneLibraryError.inaccessible(
                    "Existe Scenes.v27.json. Ejecuta la migración de mantenimiento v27→v28 antes de abrir la biblioteca."
                )
            }
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
            .appendingPathComponent("Autosave.v25", isDirectory: true)
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
            try validateStrictAutosaveShape(data)
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

    private func validateStrictAutosaveShape(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              {
                  let keys = Set(root.keys)
                  let required: Set<String> = [
                      "schema", "id", "originalSceneID", "sceneName", "savedAt", "snapshot",
                      "thumbnailFileName",
                  ]
                  let allowed = required.union(["generatedEnvironmentFileName"])
                  return required.isSubset(of: keys) && keys.isSubset(of: allowed)
              }(),
              let snapshot = root["snapshot"] as? [String: Any],
              SavedSceneSnapshot.hasStrictTopLevelShape(snapshot) else {
            throw SceneLibraryError.invalidDocument(
                "La copia de recuperación contiene campos desconocidos."
            )
        }
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
              Set(root.keys) == ["schemaVersion", "scenes", "productions", "unclassifiedSceneIDs"],
              let scenes = root["scenes"] as? [[String: Any]],
              root["unclassifiedSceneIDs"] is [String],
              let productions = root["productions"] as? [[String: Any]]
        else { throw SceneLibraryError.invalidDocument("Contrato de biblioteca desconocido.") }
        for production in productions {
            guard (Set(production.keys) == ["id", "name", "seasonSlug", "association", "episodes"]
                    || Set(production.keys) == ["id", "name", "seasonSlug", "episodes"]),
                  let episodes = production["episodes"] as? [[String: Any]],
                  (production["association"] == nil || production["association"] is NSNull || {
                      guard let value = production["association"] as? [String: Any] else { return false }
                      return Set(value.keys) == [
                          "productionId", "productionRootPath", "productionSlug", "seasonSlug", "destinations",
                      ] && (value["destinations"] as? [[String: Any]])?.allSatisfy({
                          Set($0.keys) == ["role", "workstreamName", "folderName", "folderSuffix"]
                      }) == true
                  }()) else { throw SceneLibraryError.invalidDocument("La Producción contiene campos desconocidos.") }
            for episode in episodes {
                guard (Set(episode.keys) == ["id", "name", "associationState", "externalReference", "shots"]
                        || Set(episode.keys) == ["id", "name", "associationState", "shots"]),
                      let shots = episode["shots"] as? [[String: Any]],
                      (episode["externalReference"] == nil || episode["externalReference"] is NSNull || {
                          guard let value = episode["externalReference"] as? [String: Any] else { return false }
                          return Set(value.keys) == [
                              "productionId", "episodeId", "episodeOrder", "episodeSlug",
                              "episodePathSegments",
                          ]
                      }()) else { throw SceneLibraryError.invalidDocument("El Episodio contiene campos desconocidos.") }
                for shot in shots {
                    guard (Set(shot.keys) == [
                        "id", "name", "associationState", "externalReference", "nextSceneOrdinal", "scenes",
                    ] || Set(shot.keys) == [
                        "id", "name", "associationState", "nextSceneOrdinal", "scenes",
                    ]), let placements = shot["scenes"] as? [[String: Any]],
                    placements.allSatisfy({ Set($0.keys) == ["sceneID", "ordinal"] }),
                    (shot["externalReference"] == nil || shot["externalReference"] is NSNull || {
                        guard let value = shot["externalReference"] as? [String: Any] else { return false }
                        return Set(value.keys) == ["productionId", "shotId", "canonicalName"]
                    }()) else { throw SceneLibraryError.invalidDocument("El Plano contiene campos desconocidos.") }
                }
            }
        }
        for scene in scenes {
            guard Set(scene.keys) == ["id", "name", "thumbnailFileName", "snapshot"],
                  let snapshot = scene["snapshot"] as? [String: Any],
                  SavedSceneSnapshot.hasStrictTopLevelShape(snapshot),
                  let source = snapshot["source"] as? [String: Any],
                  Set(source.keys) == ["kind", "assets", "missingMedia"]
                    || Set(source.keys) == ["kind", "patternRawValue", "assets"],
                  let assets = source["assets"] as? [[String: Any]],
                  assets.allSatisfy({ Set($0.keys) == ["absolutePath"] }),
                  let authoring = snapshot["authoring"] as? [String: Any],
                  (Set(authoring.keys) == [
                      "schema", "profiles", "overrides", "modelOverrides", "context",
                  ] || Set(authoring.keys) == [
                      "schema", "profiles", "overrides", "modelOverrides", "context",
                      "environmentCalibration",
                  ]),
                  let profiles = authoring["profiles"] as? [String: Any],
                  Set(profiles.keys) == [
                      "deviceID", "coverGlassID", "captureID", "lensID", "environmentID",
                      "deliveryID", "recordingID",
                  ],
                  let overrides = authoring["overrides"] as? [[String: Any]],
                  overrides.allSatisfy({ override in
                      guard let kind = override["kind"] as? String else { return false }
                      return Set(override.keys) == ["controlID", "kind", kind]
                  }),
                  let modelOverrides = authoring["modelOverrides"] as? [String: Any],
                  (Set(modelOverrides.keys) == ["stages"]
                    || Set(modelOverrides.keys) == ["screen", "stages"]),
                  let context = authoring["context"] as? [String: Any],
                  Set(context.keys) == [
                      "sourceInputTransformID", "sourceAlphaMode", "sourceColorModel",
                      "sourceYUVMatrix", "sourceSignalRange", "sourcePlacementID",
                      "previewOutputTransformID", "previewPhaseID", "environmentResource",
                      "referencePlateID", "referenceResource",
                  ],
                  let environmentResource = context["environmentResource"] as? [String: Any],
                  (Set(environmentResource.keys) == ["kind"]
                    || Set(environmentResource.keys) == [
                        "kind", "fileName", "absolutePath", "inputTransformID",
                    ]),
                  let referenceResource = context["referenceResource"] as? [String: Any],
                  (Set(referenceResource.keys) == ["kind", "corners"]
                    || Set(referenceResource.keys) == [
                        "kind", "fileName", "absolutePath", "inputTransformID", "alphaMode",
                        "signalColorModel", "signalMatrix", "signalRange", "placementID", "corners",
                    ]),
                  (referenceResource["corners"] as? [[String: Any]])?.allSatisfy({
                      Set($0.keys) == ["x", "y"]
                  }) == true,
                  (authoring["environmentCalibration"] == nil
                    || authoring["environmentCalibration"] is NSNull || {
                      guard let calibration = authoring["environmentCalibration"]
                        as? [String: Any] else { return false }
                      return Set(calibration.keys) == [
                          "schema", "inputTransformID",
                          "sourceUnitRadianceCandelasPerSquareMeter", "exposureEV",
                      ]
                  }()),
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
                                "scene", "cameraID", "pointGroupID", "visibleMeshIDs",
                                "pointsVisible", "geometryVisible", "cameraEnabled", "calibration",
                            ],
                            let authoredScene = tracking["scene"] as? [String: Any],
                            Set(authoredScene.keys) == [
                                "schema", "cameras", "pointGroups", "meshes",
                            ],
                            let cameras = authoredScene["cameras"] as? [[String: Any]],
                            cameras.allSatisfy({ camera in
                                Set(camera.keys) == [
                                    "id", "label", "frameRateNumerator", "frameRateDenominator",
                                    "focalLengthMillimeters", "gateWidthMillimeters",
                                    "gateHeightMillimeters", "plateWidth", "plateHeight",
                                    "distortion", "samples",
                                ]
                                && {
                                    guard let distortion = camera["distortion"] as? [String: Any]
                                    else { return false }
                                    if Set(distortion.keys) == ["pinhole"],
                                       let value = distortion["pinhole"] as? [String: Any] {
                                        return value.isEmpty
                                    }
                                    if Set(distortion.keys) == ["de4RadialStandardDegree4"],
                                       let value = distortion["de4RadialStandardDegree4"]
                                        as? [String: Any] {
                                        return Set(value.keys) == ["degree2", "degree4"]
                                    }
                                    return false
                                }()
                                && (camera["samples"] as? [[String: Any]])?.allSatisfy({ sample in
                                    Set(sample.keys) == ["frame", "sourcePosition", "orientation"]
                                }) == true
                            }),
                            let pointGroups = authoredScene["pointGroups"] as? [[String: Any]],
                            pointGroups.allSatisfy({ group in
                                Set(group.keys) == ["id", "label", "points"]
                                && (group["points"] as? [[String: Any]])?.allSatisfy({ point in
                                    Set(point.keys) == ["id", "label", "sourcePosition"]
                                }) == true
                            }),
                            let meshes = authoredScene["meshes"] as? [[String: Any]],
                            meshes.allSatisfy({ mesh in
                                Set(mesh.keys) == [
                                    "id", "label", "sourceVertices", "faceVertexCounts",
                                    "faceVertexIndices",
                                ]
                            }),
                            let calibration = tracking["calibration"] as? [String: Any],
                            Set(calibration.keys) == [
                                "unitValue", "unit", "metersPerSourceUnit",
                            ] else { return false }
                      return true
                  }()),
                  (snapshot["trackingSceneMethod"] as? String).flatMap(
                    TrackingSceneMethod.init(rawValue:)
                  ) != nil,
                  (snapshot["fusionTrackerMotion"] == nil
                    || snapshot["fusionTrackerMotion"] is NSNull || {
                      guard let motion = snapshot["fusionTrackerMotion"] as? [String: Any],
                            Set(motion.keys) == [
                                "schema", "target", "anchorFrame", "frameRateNumerator",
                                "frameRateDenominator", "samples",
                            ],
                            let samples = motion["samples"] as? [[String: Any]],
                            samples.allSatisfy({ sample in
                                Set(sample.keys) == ["frame", "position", "orientation"]
                            }) else { return false }
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

    func sortedScenes(_ ids: [UUID]) -> [SavedScene] {
        let selected = Set(ids)
        return document.scenes.filter { selected.contains($0.id) }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }

    @discardableResult
    func createProduction(name: String, seasonSlug: String = "") throws -> SceneProduction {
        let production = SceneProduction(name: try requiredName(name, kind: "Producción"), seasonSlug: seasonSlug)
        try persist { $0.productions.append(production) }
        return production
    }

    @discardableResult
    func createAssociatedProduction(
        name: String, association: ShotManagerProductionAssociation,
        projection: ShotManagerProductionProjection
    ) throws -> SceneProduction {
        try association.validate()
        try projection.validate()
        guard association.productionId == projection.productionId else {
            throw SceneLibraryError.invalidDocument("La asociación no pertenece al JSON seleccionado.")
        }
        guard productionsAssociated(with: association.productionId).isEmpty else {
            throw SceneLibraryError.invalidDocument(
                "Esta Producción de Shot Manager ya está asociada. Reconecta la entrada local existente."
            )
        }
        let production = SceneProduction(
            name: try requiredName(name, kind: "Producción"),
            seasonSlug: association.seasonSlug, association: association
        )
        try persist { $0.productions.append(production) }
        return production
    }

    @discardableResult
    func createEpisode(in productionID: UUID, name: String) throws -> SceneEpisode {
        let episode = SceneEpisode(name: try requiredName(name, kind: "Episodio"))
        try persist { candidate in
            guard let index = candidate.productions.firstIndex(where: { $0.id == productionID }) else {
                throw SceneLibraryError.inaccessible("La Producción ya no existe.")
            }
            candidate.productions[index].episodes.append(episode)
        }
        return episode
    }

    @discardableResult
    func createShot(in episodeID: UUID, name: String) throws -> SceneShot {
        let shot = SceneShot(name: try requiredName(name, kind: "Plano"))
        try persist { candidate in
            guard let location = candidate.episodeLocation(id: episodeID) else {
                throw SceneLibraryError.inaccessible("El Episodio ya no existe.")
            }
            candidate.productions[location.production].episodes[location.episode].shots.append(shot)
        }
        return shot
    }

    func moveScene(_ sceneID: UUID, to shotID: UUID?) throws {
        try persist { candidate in
            let currentShotID = candidate.shotContaining(sceneID: sceneID)?.shot.id
            guard currentShotID != shotID else { return }
            candidate.unclassifiedSceneIDs.removeAll { $0 == sceneID }
            for productionIndex in candidate.productions.indices {
                for episodeIndex in candidate.productions[productionIndex].episodes.indices {
                    for shotIndex in candidate.productions[productionIndex].episodes[episodeIndex].shots.indices {
                        candidate.productions[productionIndex].episodes[episodeIndex].shots[shotIndex]
                            .scenes.removeAll { $0.sceneID == sceneID }
                    }
                }
            }
            guard let shotID else {
                candidate.unclassifiedSceneIDs.append(sceneID)
                return
            }
            guard let location = candidate.shotLocation(id: shotID) else {
                throw SceneLibraryError.inaccessible("El Plano ya no existe.")
            }
            var shot = candidate.productions[location.production].episodes[location.episode].shots[location.shot]
            guard shot.nextSceneOrdinal <= 999 else {
                throw SceneLibraryError.invalidDocument("El Plano ha agotado sus 999 ordinales de escena.")
            }
            let ordinal = shot.nextSceneOrdinal
            shot.scenes.append(.init(sceneID: sceneID, ordinal: ordinal))
            shot.nextSceneOrdinal += 1
            candidate.productions[location.production].episodes[location.episode].shots[location.shot] = shot
            candidate.renameScene(sceneID, for: shot.name, ordinal: ordinal)
        }
    }

    func associateProduction(
        _ productionID: UUID, association: ShotManagerProductionAssociation,
        projection: ShotManagerProductionProjection, replacingProduction: Bool
    ) throws {
        try association.validate()
        try projection.validate()
        try persist { candidate in
            guard let productionIndex = candidate.productions.firstIndex(where: { $0.id == productionID }) else {
                throw SceneLibraryError.inaccessible("La Producción ya no existe.")
            }
            let previous = candidate.productions[productionIndex].association
            if let previous, previous.productionId != association.productionId, !replacingProduction {
                throw ShotManagerAssociationError.differentProduction
            }
            candidate.productions[productionIndex].association = association
            candidate.productions[productionIndex].seasonSlug = association.seasonSlug
            if previous?.productionId == association.productionId {
                candidate.refreshReferences(productionIndex: productionIndex, from: projection)
            } else {
                candidate.freeAllReferences(productionIndex: productionIndex)
            }
        }
    }

    func selectOfflineRoot(_ productionID: UUID, root: URL) throws {
        let canonical = try ShotManagerAssociationService.canonicalExistingRoot(root)
        try persist { candidate in
            guard let index = candidate.productions.firstIndex(where: { $0.id == productionID }),
                  candidate.productions[index].association != nil else {
                throw SceneLibraryError.inaccessible("La Producción no está asociada.")
            }
            candidate.productions[index].association?.productionRootPath = canonical.path
        }
    }

    func makeProductionManual(_ productionID: UUID) throws {
        try persist { candidate in
            guard let index = candidate.productions.firstIndex(where: { $0.id == productionID }) else {
                throw SceneLibraryError.inaccessible("La Producción ya no existe.")
            }
            candidate.productions[index].association = nil
            candidate.freeAllReferences(productionIndex: index)
        }
    }

    func productionsAssociated(with externalProductionID: String) -> [SceneProduction] {
        document.productions.filter {
            $0.association?.productionId == externalProductionID
        }
    }

    func associateEpisode(_ episodeID: UUID, with external: ShotManagerEpisodeProjection) throws {
        try persist { candidate in
            guard let location = candidate.episodeLocation(id: episodeID),
                  let association = candidate.productions[location.production].association else {
                throw SceneLibraryError.inaccessible("El Episodio necesita una Producción asociada.")
            }
            var episode = candidate.productions[location.production].episodes[location.episode]
            episode.externalReference = .init(
                productionId: association.productionId, episodeId: external.id,
                episodeOrder: external.order, episodeSlug: external.slug,
                episodePathSegments: external.pathSegments
            )
            episode.associationState = .associated
            episode.name = try requiredName(external.slug, kind: "Episodio externo")
            for index in episode.shots.indices { episode.shots[index].associationState = .free }
            candidate.productions[location.production].episodes[location.episode] = episode
        }
    }

    func associateShot(_ shotID: UUID, with external: ShotManagerShotProjection) throws {
        try persist { candidate in
            guard let location = candidate.shotLocation(id: shotID) else {
                throw SceneLibraryError.inaccessible("El Plano ya no existe.")
            }
            var episode = candidate.productions[location.production].episodes[location.episode]
            guard let episodeReference = episode.externalReference,
                  episode.associationState == .associated,
                  episodeReference.episodeId == external.episodeId else {
                throw SceneLibraryError.invalidDocument("El Plano externo no pertenece al Episodio asociado.")
            }
            episode.shots[location.shot].externalReference = .init(
                productionId: episodeReference.productionId,
                shotId: external.id, canonicalName: external.canonicalName
            )
            episode.shots[location.shot].associationState = .associated
            episode.shots[location.shot].name = external.canonicalName
            candidate.renamePlacedScenes(for: episode.shots[location.shot])
            candidate.productions[location.production].episodes[location.episode] = episode
        }
    }

    func associatedRenderTarget(for sceneID: UUID, role: String = "render") throws -> ShotManagerAssociatedRenderTarget? {
        guard let location = document.shotContaining(sceneID: sceneID),
              let production = document.productions.first(where: { $0.id == location.production.id }),
              let association = production.association,
              location.episode.associationState == .associated,
              let episode = location.episode.externalReference,
              location.shot.associationState == .associated,
              let shot = location.shot.externalReference,
              let placement = location.shot.scenes.first(where: { $0.sceneID == sceneID }) else { return nil }
        return try ShotManagerAssociationService.materializeDestination(
            production: association, episodePathSegments: episode.episodePathSegments,
            canonicalName: shot.canonicalName, sceneOrdinal: placement.ordinal, role: role
        )
    }

    private func requiredName(_ value: String, kind: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw SceneLibraryError.invalidDocument("\(kind) necesita un nombre.")
        }
        return name
    }

    private func persist(_ mutation: (inout SceneLibraryDocument) throws -> Void) throws {
        guard let store else { throw SceneLibraryError.inaccessible("Sin destino de escenas.") }
        var candidate = document
        try mutation(&candidate)
        try store.save(candidate)
        document = candidate
    }

    func autosaveHistoryTarget(for scene: SavedScene) -> SceneAutosaveHistoryTarget {
        .init(sceneID: scene.id, sceneName: scene.name, isDeletedScene: false)
    }

    func deletedAutosaveHistoryTargets() throws -> [SceneAutosaveHistoryTarget] {
        guard let store else { throw SceneLibraryError.inaccessible("Sin destino de escenas.") }
        let root = store.directoryURL.deletingLastPathComponent()
            .appendingPathComponent("Autosave.v25", isDirectory: true)
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
    func add(
        capture: SavedSceneCapture,
        name: String? = nil,
        toShotID shotID: UUID? = nil
    ) throws -> SavedScene {
        guard let store else { throw SceneLibraryError.inaccessible("Sin destino de escenas.") }
        let id = UUID()
        var candidate = document
        let resolvedName: String
        if let shotID {
            guard let location = candidate.shotLocation(id: shotID) else {
                throw SceneLibraryError.inaccessible("El Plano ya no existe.")
            }
            var shot = candidate.productions[location.production].episodes[location.episode]
                .shots[location.shot]
            guard shot.nextSceneOrdinal <= 999 else {
                throw SceneLibraryError.invalidDocument(
                    "El Plano ha agotado sus 999 ordinales de escena."
                )
            }
            let ordinal = shot.nextSceneOrdinal
            resolvedName = "\(shot.name)_\(String(format: "%03d", ordinal))"
            shot.scenes.append(.init(sceneID: id, ordinal: ordinal))
            shot.nextSceneOrdinal += 1
            candidate.productions[location.production].episodes[location.episode]
                .shots[location.shot] = shot
        } else {
            resolvedName = name ?? "Escena \(document.scenes.count + 1)"
            candidate.unclassifiedSceneIDs.insert(id, at: 0)
        }
        let generated = try capture.generatedEnvironmentEXR.map {
            let managed = try EnvironmentAssetLibrary.storeSceneGeneratedEXR(
                $0, sceneID: id, libraryRoot: store.environmentLibraryRoot
            )
            return (SavedSceneAsset(fileName: managed.originalFileName, sha256: managed.sha256), managed.url.path)
        }
        let snapshot = try capture.snapshot.replacingGeneratedEnvironment(generated?.0, absolutePath: generated?.1)
        let scene = SavedScene(
            id: id,
            name: resolvedName,
            thumbnailFileName: "\(id.uuidString.lowercased()).png",
            snapshot: snapshot
        )
        try scene.validate()
        _ = try store.writeAutosave(
            scene: scene, thumbnailPNG: capture.thumbnailPNG,
            generatedEnvironmentEXR: capture.generatedEnvironmentEXR
        )
        try store.writeThumbnail(capture.thumbnailPNG, for: scene)
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

    func settingsClipboard(
        for scene: SavedScene,
        blocks: Set<SceneSettingsBlock>
    ) throws -> SceneSettingsClipboardDocument {
        guard let current = self.scene(id: scene.id) else {
            throw SceneLibraryError.inaccessible("La escena ya no existe.")
        }
        let stored = try storedUpdate(sceneID: current.id)
        return try SceneSettingsClipboardDocument(
            source: current,
            includedBlocks: blocks,
            generatedEnvironmentEXR: blocks.contains(.environment)
                ? stored.generatedEnvironmentEXR : nil
        )
    }

    @discardableResult
    func resetToDefaults(
        _ scene: SavedScene,
        snapshot: SavedSceneSnapshot,
        destination: SceneDefaultResetDestination,
        undoManager: UndoManager? = nil
    ) throws -> SavedScene {
        let stored = try storedUpdate(sceneID: scene.id)
        let base = switch destination {
        case .storedScene:
            SavedSceneCapture(
                snapshot: stored.snapshot,
                thumbnailPNG: stored.thumbnailPNG,
                generatedEnvironmentEXR: stored.generatedEnvironmentEXR
            )
        case let .activeScene(capture):
            capture
        }
        let source = base.snapshot.authoring.context
        let reset = snapshot.authoring.context
        guard snapshot.source == base.snapshot.source,
              reset.sourceInputTransformID == source.sourceInputTransformID,
              reset.sourceAlphaMode == source.sourceAlphaMode,
              reset.sourceColorModel == source.sourceColorModel,
              reset.sourceYUVMatrix == source.sourceYUVMatrix,
              reset.sourceSignalRange == source.sourceSignalRange,
              reset.sourcePlacementID == source.sourcePlacementID,
              reset.referencePlateID == source.referencePlateID,
              reset.referenceResource == source.referenceResource,
              snapshot.generatedEnvironment == nil,
              snapshot.tracking == nil
        else {
            throw SceneLibraryError.invalidDocument(
                "El reset debe conservar exactamente Source y Reference."
            )
        }
        try update(
            scene,
            capture: SavedSceneCapture(
                snapshot: snapshot,
                thumbnailPNG: base.thumbnailPNG,
                generatedEnvironmentEXR: nil
            ),
            undoManager: undoManager
        )
        guard let updated = self.scene(id: scene.id) else {
            throw SceneLibraryError.inaccessible("La escena restaurada ya no existe.")
        }
        return updated
    }

    @discardableResult
    func removeImported3D(
        _ scene: SavedScene,
        destination: SceneImported3DRemovalDestination,
        undoManager: UndoManager? = nil
    ) throws -> SavedScene {
        let stored = try storedUpdate(sceneID: scene.id)
        let base = switch destination {
        case .storedScene: stored.capture
        case let .activeScene(capture): capture
        }
        guard base.snapshot.tracking != nil else {
            throw SceneLibraryError.invalidDocument(
                "La escena no contiene una importación 3D."
            )
        }
        try update(
            scene,
            capture: SavedSceneCapture(
                snapshot: base.snapshot.removingImported3D(),
                thumbnailPNG: base.thumbnailPNG,
                generatedEnvironmentEXR: base.generatedEnvironmentEXR
            ),
            undoManager: undoManager
        )
        guard let updated = self.scene(id: scene.id) else {
            throw SceneLibraryError.inaccessible("La escena actualizada ya no existe.")
        }
        return updated
    }

    @discardableResult
    func applySettingsClipboard(
        _ clipboard: SceneSettingsClipboardDocument,
        blocks: Set<SceneSettingsBlock>,
        to scene: SavedScene,
        destination: SceneSettingsPasteDestination,
        ownership: SceneSettingsOwnership,
        undoManager: UndoManager? = nil
    ) throws -> SavedScene {
        guard blocks.isSubset(of: Set(clipboard.includedBlocks)) else {
            throw SceneLibraryError.invalidDocument(
                "Se han seleccionado tarjetas ausentes del portapapeles."
            )
        }
        let stored = try storedUpdate(sceneID: scene.id)
        let target = switch destination {
        case .storedScene:
            SavedSceneCapture(
                snapshot: stored.snapshot,
                thumbnailPNG: stored.thumbnailPNG,
                generatedEnvironmentEXR: stored.generatedEnvironmentEXR
            )
        case let .activeScene(capture):
            capture
        }
        let snapshot = try target.snapshot.applyingSettings(
            from: clipboard.snapshot,
            blocks: blocks,
            ownership: ownership
        )
        let environment = blocks.contains(.environment)
            ? clipboard.generatedEnvironmentEXR : target.generatedEnvironmentEXR
        try update(
            scene,
            capture: SavedSceneCapture(
                snapshot: snapshot,
                thumbnailPNG: target.thumbnailPNG,
                generatedEnvironmentEXR: environment
            ),
            undoManager: undoManager
        )
        guard let updated = self.scene(id: scene.id) else {
            throw SceneLibraryError.inaccessible("La escena pegada ya no existe.")
        }
        return updated
    }

    func rename(_ scene: SavedScene, to name: String) throws {
        guard let store, let index = document.scenes.firstIndex(where: { $0.id == scene.id })
        else { throw SceneLibraryError.inaccessible("La escena ya no existe.") }
        guard document.shotContaining(sceneID: scene.id) == nil else {
            throw SceneLibraryError.invalidDocument(
                "El nombre de una Escena asociada procede de su Plano. Muévela a Sin clasificar para editarlo."
            )
        }
        let committedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !committedName.isEmpty else {
            throw SceneLibraryError.invalidDocument("El nombre de la escena está vacío.")
        }
        var candidate = document
        candidate.scenes[index].name = committedName
        try store.save(candidate)
        document = candidate
    }

    func renameProduction(_ productionID: UUID, to name: String) throws {
        let committed = try requiredName(name, kind: "Producción")
        try persist { candidate in
            guard let index = candidate.productions.firstIndex(where: { $0.id == productionID }) else {
                throw SceneLibraryError.inaccessible("La Producción ya no existe.")
            }
            candidate.productions[index].name = committed
        }
    }

    func setProductionSeason(_ productionID: UUID, to seasonSlug: String) throws {
        let committed = seasonSlug.trimmingCharacters(in: .whitespacesAndNewlines)
        try persist { candidate in
            guard let index = candidate.productions.firstIndex(where: { $0.id == productionID }) else {
                throw SceneLibraryError.inaccessible("La Producción ya no existe.")
            }
            guard candidate.productions[index].association == nil else {
                throw SceneLibraryError.invalidDocument(
                    "La temporada de una Producción asociada procede de Shot Manager."
                )
            }
            candidate.productions[index].seasonSlug = committed
        }
    }

    func renameEpisode(_ episodeID: UUID, to name: String) throws {
        let committed = try requiredName(name, kind: "Episodio")
        try persist { candidate in
            guard let location = candidate.episodeLocation(id: episodeID) else {
                throw SceneLibraryError.inaccessible("El Episodio ya no existe.")
            }
            guard candidate.productions[location.production].episodes[location.episode]
                .associationState == .free else {
                throw SceneLibraryError.invalidDocument(
                    "El nombre de un Episodio asociado procede de Shot Manager. Déjalo libre para editarlo."
                )
            }
            candidate.productions[location.production].episodes[location.episode].name = committed
        }
    }

    func renameShot(_ shotID: UUID, to name: String) throws {
        let committed = try requiredName(name, kind: "Plano")
        try persist { candidate in
            guard let location = candidate.shotLocation(id: shotID) else {
                throw SceneLibraryError.inaccessible("El Plano ya no existe.")
            }
            var shot = candidate.productions[location.production].episodes[location.episode]
                .shots[location.shot]
            guard shot.associationState == .free else {
                throw SceneLibraryError.invalidDocument(
                    "El nombre de un Plano asociado procede de Shot Manager. Déjalo libre para editarlo."
                )
            }
            shot.name = committed
            candidate.productions[location.production].episodes[location.episode]
                .shots[location.shot] = shot
            candidate.renamePlacedScenes(for: shot)
        }
    }

    func makeEpisodeFree(_ episodeID: UUID) throws {
        try persist { candidate in
            guard let location = candidate.episodeLocation(id: episodeID) else {
                throw SceneLibraryError.inaccessible("El Episodio ya no existe.")
            }
            candidate.productions[location.production].episodes[location.episode]
                .associationState = .free
            for shot in candidate.productions[location.production].episodes[location.episode].shots.indices {
                candidate.productions[location.production].episodes[location.episode]
                    .shots[shot].associationState = .free
            }
        }
    }

    func makeShotFree(_ shotID: UUID) throws {
        try persist { candidate in
            guard let location = candidate.shotLocation(id: shotID) else {
                throw SceneLibraryError.inaccessible("El Plano ya no existe.")
            }
            candidate.productions[location.production].episodes[location.episode]
                .shots[location.shot].associationState = .free
        }
    }

    func deleteProduction(_ productionID: UUID) throws {
        try persist { candidate in
            guard let index = candidate.productions.firstIndex(where: { $0.id == productionID }) else {
                throw SceneLibraryError.inaccessible("La Producción ya no existe.")
            }
            guard candidate.productions[index].episodes.isEmpty else {
                throw SceneLibraryError.invalidDocument("Elimina primero los Episodios de la Producción.")
            }
            candidate.productions.remove(at: index)
        }
    }

    func deleteEpisode(_ episodeID: UUID) throws {
        try persist { candidate in
            guard let location = candidate.episodeLocation(id: episodeID) else {
                throw SceneLibraryError.inaccessible("El Episodio ya no existe.")
            }
            guard candidate.productions[location.production].episodes[location.episode].shots.isEmpty else {
                throw SceneLibraryError.invalidDocument("Elimina primero los Planos del Episodio.")
            }
            candidate.productions[location.production].episodes.remove(at: location.episode)
        }
    }

    func deleteShot(_ shotID: UUID) throws {
        try persist { candidate in
            guard let location = candidate.shotLocation(id: shotID) else {
                throw SceneLibraryError.inaccessible("El Plano ya no existe.")
            }
            guard candidate.productions[location.production].episodes[location.episode]
                .shots[location.shot].scenes.isEmpty else {
                throw SceneLibraryError.invalidDocument("Mueve primero las escenas fuera del Plano.")
            }
            candidate.productions[location.production].episodes[location.episode]
                .shots.remove(at: location.shot)
        }
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
        let register = {
            undoManager.registerUndo(withTarget: self) { target in
                MainActor.assumeIsolated {
                    target.restoreUpdate(
                        sceneID: sceneID,
                        state: state,
                        undoManager: manager.value
                    )
                }
            }
        }
        if undoManager.isUndoing || undoManager.isRedoing {
            register()
            undoManager.setActionName("Actualizar escena")
        } else {
            let groupedByEvent = undoManager.groupsByEvent
            undoManager.groupsByEvent = false
            undoManager.beginUndoGrouping()
            register()
            undoManager.setActionName("Actualizar escena")
            undoManager.endUndoGrouping()
            undoManager.groupsByEvent = groupedByEvent
        }
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
        if let containing = candidate.shotContaining(sceneID: scene.id),
           let location = candidate.shotLocation(id: containing.shot.id),
           candidate.productions[location.production].episodes[location.episode]
            .shots[location.shot].nextSceneOrdinal <= 999 {
            let ordinal = candidate.productions[location.production].episodes[location.episode]
                .shots[location.shot].nextSceneOrdinal
            candidate.productions[location.production].episodes[location.episode]
                .shots[location.shot].scenes.append(.init(sceneID: duplicate.id, ordinal: ordinal))
            candidate.productions[location.production].episodes[location.episode]
                .shots[location.shot].nextSceneOrdinal += 1
        } else {
            candidate.unclassifiedSceneIDs.insert(duplicate.id, at: 0)
        }
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
        candidate.unclassifiedSceneIDs.removeAll { $0 == scene.id }
        for production in candidate.productions.indices {
            for episode in candidate.productions[production].episodes.indices {
                for shot in candidate.productions[production].episodes[episode].shots.indices {
                    candidate.productions[production].episodes[episode].shots[shot]
                        .scenes.removeAll { $0.sceneID == scene.id }
                }
            }
        }
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
