import Foundation

enum ExternalMediaRole: Hashable, Sendable {
    case source(index: Int, count: Int)
    case reference
    case environment

    var label: String {
        switch self {
        case let .source(index, count):
            count == 1 ? "Source" : "Source \(index + 1) de \(count)"
        case .reference:
            "Reference"
        case .environment:
            "HDRI de entorno"
        }
    }
}

struct ExternalMediaUsage: Identifiable, Hashable, Sendable {
    let sceneID: UUID
    let sceneName: String
    let role: ExternalMediaRole
    let authoredPath: String
    let exists: Bool

    var id: String { "\(sceneID.uuidString):\(role):\(authoredPath)" }
    var systemItem: String { "Escena · \(sceneName) › \(role.label)" }
    var absoluteDirectoryPath: String {
        URL(fileURLWithPath: authoredPath).deletingLastPathComponent().path
    }
    var fileName: String { URL(fileURLWithPath: authoredPath).lastPathComponent }
}

extension SceneLibraryController {
    func externalMediaUsages(fileManager: FileManager = .default) -> [ExternalMediaUsage] {
        document.scenes.flatMap { scene in
            var usages: [ExternalMediaUsage] = []
            if scene.snapshot.source.kind == .externalMedia {
                let assets = scene.snapshot.source.assets
                usages.append(contentsOf: assets.enumerated().map { index, asset in
                    ExternalMediaUsage(
                        sceneID: scene.id,
                        sceneName: scene.name,
                        role: .source(index: index, count: assets.count),
                        authoredPath: asset.absolutePath,
                        exists: fileManager.fileExists(atPath: asset.absolutePath)
                    )
                })
            }
            let reference = scene.snapshot.authoring.context.referenceResource
            if reference.kind == .imageOrVideo, let path = reference.absolutePath {
                usages.append(ExternalMediaUsage(
                    sceneID: scene.id,
                    sceneName: scene.name,
                    role: .reference,
                    authoredPath: path,
                    exists: fileManager.fileExists(atPath: path)
                ))
            }
            let environment = scene.snapshot.authoring.context.environmentResource
            if environment.kind == .image,
               scene.snapshot.generatedEnvironment == nil,
               let path = environment.absolutePath {
                usages.append(ExternalMediaUsage(
                    sceneID: scene.id,
                    sceneName: scene.name,
                    role: .environment,
                    authoredPath: path,
                    exists: fileManager.fileExists(atPath: path)
                ))
            }
            return usages
        }
    }

    @discardableResult
    func replaceExternalMedia(
        _ usage: ExternalMediaUsage,
        with replacementURL: URL
    ) throws -> SavedScene {
        let path = replacementURL.standardizedFileURL.path
        guard path.hasPrefix("/"), !replacementURL.lastPathComponent.isEmpty else {
            throw SceneLibraryError.invalidDocument("La nueva ruta de media no es válida.")
        }
        try persistExternalMediaChanges { candidate in
            try Self.replaceExternalMedia(usage, with: path, in: &candidate)
        }
        guard let updated = scene(id: usage.sceneID) else {
            throw SceneLibraryError.inaccessible("La escena actualizada ya no existe.")
        }
        return updated
    }

    @discardableResult
    func changeExternalMediaSourceDirectory(
        for selected: ExternalMediaUsage,
        to destinationURL: URL
    ) throws -> [SavedScene] {
        let source = URL(
            fileURLWithPath: selected.absoluteDirectoryPath,
            isDirectory: true
        ).standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        let matches = externalMediaUsages().filter {
            Self.isSameOrDescendantDirectory(
                source,
                URL(fileURLWithPath: $0.absoluteDirectoryPath, isDirectory: true)
                    .standardizedFileURL
            )
        }
        guard !matches.isEmpty else {
            throw SceneLibraryError.invalidDocument(
                "Ninguna referencia declarada usa el directorio de origen seleccionado."
            )
        }
        try persistExternalMediaChanges { candidate in
            for usage in matches {
                let target = try Self.reassociatedTargetPath(
                    from: source,
                    to: destination,
                    currentTarget: URL(fileURLWithPath: usage.authoredPath)
                )
                try Self.replaceExternalMedia(usage, with: target.path, in: &candidate)
            }
        }
        let changedIDs = Set(matches.map(\.sceneID))
        return document.scenes.filter { changedIDs.contains($0.id) }
    }

    static func isSameOrDescendantDirectory(_ source: URL, _ candidate: URL) -> Bool {
        let sourceComponents = source.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        return candidateComponents.count >= sourceComponents.count
            && Array(candidateComponents.prefix(sourceComponents.count)) == sourceComponents
    }

    static func reassociatedTargetPath(
        from source: URL,
        to destination: URL,
        currentTarget: URL
    ) throws -> URL {
        let sourceComponents = source.standardizedFileURL.pathComponents
        let targetComponents = currentTarget.standardizedFileURL.pathComponents
        guard targetComponents.count > sourceComponents.count,
              Array(targetComponents.prefix(sourceComponents.count)) == sourceComponents
        else {
            throw SceneLibraryError.invalidDocument(
                "La media seleccionada queda fuera del directorio de origen."
            )
        }
        return targetComponents.dropFirst(sourceComponents.count).reduce(
            destination.standardizedFileURL
        ) { partial, component in
            partial.appendingPathComponent(component)
        }
    }

    private static func replaceExternalMedia(
        _ usage: ExternalMediaUsage,
        with path: String,
        in document: inout SceneLibraryDocument
    ) throws {
        guard let sceneIndex = document.scenes.firstIndex(where: { $0.id == usage.sceneID }) else {
            throw SceneLibraryError.inaccessible("La escena propietaria ya no existe.")
        }
        let scene = document.scenes[sceneIndex]
        let snapshot = scene.snapshot
        let context = snapshot.authoring.context
        let replacementName = URL(fileURLWithPath: path).lastPathComponent
        let source: SavedSceneSource
        let environment: PhysicalSettingsExchange.EnvironmentResource
        let reference: PhysicalSettingsExchange.ReferenceResource

        switch usage.role {
        case let .source(index, count):
            guard snapshot.source.kind == .externalMedia,
                  snapshot.source.assets.count == count,
                  snapshot.source.assets.indices.contains(index),
                  snapshot.source.assets[index].absolutePath == usage.authoredPath
            else { throw SceneLibraryError.invalidDocument("La referencia Source ya ha cambiado.") }
            var assets = snapshot.source.assets
            assets[index] = SavedExternalAsset(absolutePath: path)
            source = SavedSceneSource(
                kind: .externalMedia,
                patternRawValue: nil,
                assets: assets,
                missingMedia: snapshot.source.missingMedia
            )
            environment = context.environmentResource
            reference = context.referenceResource
        case .reference:
            guard context.referenceResource.kind == .imageOrVideo,
                  context.referenceResource.absolutePath == usage.authoredPath
            else { throw SceneLibraryError.invalidDocument("La referencia Reference ya ha cambiado.") }
            source = snapshot.source
            environment = context.environmentResource
            let previous = context.referenceResource
            reference = .init(
                kind: .imageOrVideo,
                fileName: replacementName,
                absolutePath: path,
                inputTransformID: previous.inputTransformID,
                alphaMode: previous.alphaMode,
                signalColorModel: previous.signalColorModel,
                signalMatrix: previous.signalMatrix,
                signalRange: previous.signalRange,
                placementID: previous.placementID,
                corners: previous.corners
            )
        case .environment:
            guard snapshot.generatedEnvironment == nil,
                  context.environmentResource.kind == .image,
                  context.environmentResource.absolutePath == usage.authoredPath
            else { throw SceneLibraryError.invalidDocument("La referencia HDRI ya ha cambiado.") }
            source = snapshot.source
            reference = context.referenceResource
            environment = .init(
                kind: .image,
                fileName: replacementName,
                absolutePath: path,
                inputTransformID: context.environmentResource.inputTransformID
            )
        }

        let replacementContext = SceneAuthoringContext(
            sourceInputTransformID: context.sourceInputTransformID,
            sourceAlphaMode: context.sourceAlphaMode,
            sourceColorModel: context.sourceColorModel,
            sourceYUVMatrix: context.sourceYUVMatrix,
            sourceSignalRange: context.sourceSignalRange,
            sourcePlacementID: context.sourcePlacementID,
            previewOutputTransformID: context.previewOutputTransformID,
            previewPhaseID: context.previewPhaseID,
            referencePlateID: context.referencePlateID,
            environmentResource: environment,
            referenceResource: reference
        )
        let authoring = SceneAuthoringDocument(
            profiles: snapshot.authoring.profiles,
            overrides: snapshot.authoring.overrides,
            modelOverrides: snapshot.authoring.modelOverrides,
            context: replacementContext,
            environmentCalibration: snapshot.authoring.environmentCalibration
        )
        document.scenes[sceneIndex].snapshot = SavedSceneSnapshot(
            source: source,
            currentFrame: snapshot.currentFrame,
            viewerZoom: snapshot.viewerZoom,
            viewerPanX: snapshot.viewerPanX,
            viewerPanY: snapshot.viewerPanY,
            viewerIsFitted: snapshot.viewerIsFitted,
            authoring: authoring,
            generatedEnvironment: snapshot.generatedEnvironment,
            tracking: snapshot.tracking,
            fusionTrackerMotion: snapshot.fusionTrackerMotion,
            trackingSceneMethod: snapshot.trackingSceneMethod,
            animation: snapshot.animation
        )
        try document.scenes[sceneIndex].validate()
    }
}
