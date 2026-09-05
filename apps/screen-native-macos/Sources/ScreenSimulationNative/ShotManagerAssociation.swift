import Foundation

struct ShotManagerEpisodeProjection: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let order: Int
    let slug: String
    let pathSegments: [String]
}

struct ShotManagerFolderProjection: Codable, Equatable, Sendable {
    let name: String
    let suffix: String
}

struct ShotManagerWorkstreamProjection: Codable, Equatable, Sendable {
    let name: String
    let folders: [ShotManagerFolderProjection]
}

struct ShotManagerShotProjection: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let episodeId: String
    let canonicalName: String
}

struct ShotManagerProductionProjection: Codable, Equatable, Sendable {
    let productionId: String
    let productionSlug: String
    let seasonSlug: String
    let episodes: [ShotManagerEpisodeProjection]
    let workstreams: [ShotManagerWorkstreamProjection]
    let shots: [ShotManagerShotProjection]

    func validate() throws {
        guard UUID(uuidString: productionId) != nil else {
            throw ShotManagerAssociationError.invalidDocument("productionId no es un UUID válido.")
        }
        try Self.requireSafeSegment(productionSlug, field: "productionSlug", allowEmpty: false)
        try Self.requireSafeNameFragment(seasonSlug, field: "seasonSlug", allowEmpty: true)
        guard Set(episodes.map(\.id)).count == episodes.count,
              episodes.allSatisfy({ UUID(uuidString: $0.id) != nil && (1...999).contains($0.order) }),
              Set(episodes.map(\.order)).count == episodes.count
        else {
            throw ShotManagerAssociationError.invalidDocument(
                "Los Episodios necesitan UUID y orden único entre 1 y 999."
            )
        }
        try episodes.forEach {
            try Self.requireSafeNameFragment($0.slug, field: "episode.slug", allowEmpty: false)
            guard !$0.pathSegments.isEmpty else {
                throw ShotManagerAssociationError.invalidDocument(
                    "episode.pathSegments necesita al menos un segmento."
                )
            }
            try $0.pathSegments.forEach {
                try Self.requireSafeSegment(
                    $0, field: "episode.pathSegments", allowEmpty: false
                )
            }
        }
        let episodeIDs = Set(episodes.map(\.id))
        guard Set(shots.map(\.id)).count == shots.count,
              shots.allSatisfy({ UUID(uuidString: $0.id) != nil && episodeIDs.contains($0.episodeId) }),
              Set(shots.map(\.canonicalName)).count == shots.count
        else {
            throw ShotManagerAssociationError.invalidDocument(
                "Los Planos necesitan UUID, Episodio existente y canonicalName único."
            )
        }
        try shots.forEach {
            try Self.requireSafeSegment($0.canonicalName, field: "shot.canonicalName", allowEmpty: false)
        }
        let workstreamKeys = workstreams.map { $0.name.folding(options: [.caseInsensitive], locale: nil) }
        guard Set(workstreamKeys).count == workstreamKeys.count else {
            throw ShotManagerAssociationError.invalidDocument("Hay Workstreams ambiguos.")
        }
        for workstream in workstreams {
            try Self.requireSafeSegment(workstream.name, field: "workstream.name", allowEmpty: false)
            let folderKeys = workstream.folders.map {
                $0.name.folding(options: [.caseInsensitive], locale: nil)
            }
            guard Set(folderKeys).count == folderKeys.count else {
                throw ShotManagerAssociationError.invalidDocument(
                    "El Workstream \(workstream.name) contiene carpetas ambiguas."
                )
            }
            for folder in workstream.folders {
                try Self.requireSafeSegment(folder.name, field: "folder.name", allowEmpty: false)
                try Self.requireSafeNameFragment(folder.suffix, field: "folder.suffix", allowEmpty: true)
            }
        }
    }

    fileprivate static func requireSafeSegment(
        _ value: String, field: String, allowEmpty: Bool
    ) throws {
        guard (allowEmpty || !value.isEmpty), value != ".", value != "..",
              !value.contains("/"), !value.contains("\\"), !value.contains("\0")
        else { throw ShotManagerAssociationError.invalidDocument("\(field) no es un segmento seguro.") }
    }

    fileprivate static func requireSafeNameFragment(
        _ value: String, field: String, allowEmpty: Bool
    ) throws {
        guard (allowEmpty || !value.isEmpty), !value.contains("/"),
              !value.contains("\\"), !value.contains("\0")
        else { throw ShotManagerAssociationError.invalidDocument("\(field) no es seguro.") }
    }
}

struct ShotManagerDestinationAssociation: Codable, Equatable, Identifiable, Sendable {
    let role: String
    let workstreamName: String
    let folderName: String
    let folderSuffix: String

    var id: String { role }

    func validate() throws {
        try ShotManagerProductionProjection.requireSafeSegment(
            role, field: "destination.role", allowEmpty: false
        )
        try ShotManagerProductionProjection.requireSafeSegment(
            workstreamName, field: "destination.workstreamName", allowEmpty: false
        )
        try ShotManagerProductionProjection.requireSafeSegment(
            folderName, field: "destination.folderName", allowEmpty: false
        )
        try ShotManagerProductionProjection.requireSafeNameFragment(
            folderSuffix, field: "destination.folderSuffix", allowEmpty: true
        )
    }
}

struct ShotManagerProductionAssociation: Codable, Equatable, Sendable {
    let productionId: String
    var productionRootPath: String
    var productionSlug: String
    var seasonSlug: String
    var destinations: [ShotManagerDestinationAssociation]

    func validate() throws {
        guard UUID(uuidString: productionId) != nil,
              URL(fileURLWithPath: productionRootPath).path == productionRootPath,
              Set(destinations.map(\.role)).count == destinations.count,
              !destinations.isEmpty
        else {
            throw SceneLibraryError.invalidDocument("La asociación de Producción no es válida.")
        }
        try ShotManagerProductionProjection.requireSafeSegment(
            productionSlug, field: "productionSlug", allowEmpty: false
        )
        try ShotManagerProductionProjection.requireSafeNameFragment(
            seasonSlug, field: "seasonSlug", allowEmpty: true
        )
        try destinations.forEach { try $0.validate() }
    }
}

struct ShotManagerEpisodeReference: Codable, Equatable, Sendable {
    let productionId: String
    let episodeId: String
    let episodeOrder: Int
    let episodeSlug: String
    let episodePathSegments: [String]

    func validate() throws {
        guard UUID(uuidString: productionId) != nil, UUID(uuidString: episodeId) != nil,
              (1...999).contains(episodeOrder)
        else { throw SceneLibraryError.invalidDocument("La referencia de Episodio no es válida.") }
        try ShotManagerProductionProjection.requireSafeNameFragment(
            episodeSlug, field: "episodeSlug", allowEmpty: false
        )
        guard !episodePathSegments.isEmpty else {
            throw SceneLibraryError.invalidDocument(
                "La referencia de Episodio necesita su ruta física canónica."
            )
        }
        do {
            try episodePathSegments.forEach {
                try ShotManagerProductionProjection.requireSafeSegment(
                    $0, field: "episodePathSegments", allowEmpty: false
                )
            }
        } catch {
            throw SceneLibraryError.invalidDocument(
                "La referencia de Episodio contiene una ruta física no válida."
            )
        }
    }
}

struct ShotManagerShotReference: Codable, Equatable, Sendable {
    let productionId: String
    let shotId: String
    let canonicalName: String

    func validate() throws {
        guard UUID(uuidString: productionId) != nil, UUID(uuidString: shotId) != nil else {
            throw SceneLibraryError.invalidDocument("La referencia de Plano no es válida.")
        }
        try ShotManagerProductionProjection.requireSafeSegment(
            canonicalName, field: "canonicalName", allowEmpty: false
        )
    }
}

struct ShotManagerDocumentRead: Sendable {
    let documentURL: URL
    let rootURL: URL
    let projection: ShotManagerProductionProjection
}

struct ShotManagerDestinationOption: Identifiable, Sendable {
    let workstream: ShotManagerWorkstreamProjection
    let folder: ShotManagerFolderProjection
    var id: String { "\(workstream.name)\u{1f}\(folder.name)" }
}

struct ShotManagerAssociatedRenderTarget: Equatable, Sendable {
    let directoryPath: String
    let outputBaseName: String
}

enum ShotManagerAssociationError: LocalizedError {
    case invalidDocument(String)
    case inaccessible(String)
    case differentProduction
    case unsafeDestination(String)

    var errorDescription: String? {
        switch self {
        case let .invalidDocument(message), let .inaccessible(message),
             let .unsafeDestination(message): message
        case .differentProduction:
            "El JSON seleccionado pertenece a otra Producción. Usa “Conectar con otra Producción…”."
        }
    }
}

enum ShotManagerAssociationService {
    static func readProductionJSON(at selectedURL: URL) throws -> ShotManagerDocumentRead {
        let canonicalURL = selectedURL.standardizedFileURL.resolvingSymlinksInPath()
        guard canonicalURL.lastPathComponent == "production.json" else {
            throw ShotManagerAssociationError.inaccessible(
                "Selecciona un archivo llamado exactamente production.json."
            )
        }
        let values = try canonicalURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else {
            throw ShotManagerAssociationError.inaccessible("production.json no es un archivo regular.")
        }
        let data = try Data(contentsOf: canonicalURL, options: .mappedIfSafe)
        let projection: ShotManagerProductionProjection
        do { projection = try JSONDecoder().decode(ShotManagerProductionProjection.self, from: data) }
        catch {
            throw ShotManagerAssociationError.invalidDocument(
                "production.json no contiene la proyección externa requerida: \(error.localizedDescription)"
            )
        }
        try projection.validate()
        return .init(
            documentURL: canonicalURL,
            rootURL: canonicalURL.deletingLastPathComponent(),
            projection: projection
        )
    }

    static func destinationOptions(
        in projection: ShotManagerProductionProjection
    ) -> [ShotManagerDestinationOption] {
        projection.workstreams.flatMap { workstream in
            workstream.folders.map { .init(workstream: workstream, folder: $0) }
        }
    }

    static func makeAssociation(
        from read: ShotManagerDocumentRead,
        role: String,
        option: ShotManagerDestinationOption
    ) throws -> ShotManagerProductionAssociation {
        try makeAssociation(from: read, selections: [(role, option)])
    }

    static func makeAssociation(
        from read: ShotManagerDocumentRead,
        selections: [(role: String, option: ShotManagerDestinationOption)]
    ) throws -> ShotManagerProductionAssociation {
        let destinations = selections.map { selection in
            ShotManagerDestinationAssociation(
                role: selection.role,
                workstreamName: selection.option.workstream.name,
                folderName: selection.option.folder.name,
                folderSuffix: selection.option.folder.suffix
            )
        }
        let association = ShotManagerProductionAssociation(
            productionId: read.projection.productionId,
            productionRootPath: read.rootURL.path,
            productionSlug: read.projection.productionSlug,
            seasonSlug: read.projection.seasonSlug,
            destinations: destinations
        )
        try association.validate()
        return association
    }

    static func refreshedAssociation(
        _ existing: ShotManagerProductionAssociation,
        from read: ShotManagerDocumentRead
    ) throws -> ShotManagerProductionAssociation {
        guard existing.productionId == read.projection.productionId else {
            throw ShotManagerAssociationError.differentProduction
        }
        let destinations = try existing.destinations.map { current in
            guard let workstream = read.projection.workstreams.first(where: {
                $0.name.compare(current.workstreamName, options: [.caseInsensitive]) == .orderedSame
            }), let folder = workstream.folders.first(where: {
                $0.name.compare(current.folderName, options: [.caseInsensitive]) == .orderedSame
            }) else {
                throw ShotManagerAssociationError.invalidDocument(
                    "El JSON no declara el destino \(current.workstreamName)/\(current.folderName)."
                )
            }
            return ShotManagerDestinationAssociation(
                role: current.role, workstreamName: workstream.name,
                folderName: folder.name, folderSuffix: folder.suffix
            )
        }
        let association = ShotManagerProductionAssociation(
            productionId: existing.productionId,
            productionRootPath: read.rootURL.path,
            productionSlug: read.projection.productionSlug,
            seasonSlug: read.projection.seasonSlug,
            destinations: destinations
        )
        try association.validate()
        return association
    }

    static func canonicalExistingRoot(_ selectedURL: URL) throws -> URL {
        let root = selectedURL.standardizedFileURL.resolvingSymlinksInPath()
        let values = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ShotManagerAssociationError.unsafeDestination(
                "La nueva raíz debe ser un directorio real existente."
            )
        }
        return root
    }

    static func materializeDestination(
        production: ShotManagerProductionAssociation,
        episodePathSegments: [String],
        canonicalName: String,
        sceneOrdinal: Int,
        role: String
    ) throws -> ShotManagerAssociatedRenderTarget {
        try production.validate()
        guard !episodePathSegments.isEmpty, (1...999).contains(sceneOrdinal),
              let destination = production.destinations.first(where: { $0.role == role })
        else {
            throw ShotManagerAssociationError.unsafeDestination(
                "La asociación no contiene una ruta de Episodio, ordinal o destino de render válido."
            )
        }
        let root = try canonicalExistingRoot(URL(fileURLWithPath: production.productionRootPath))
        let segments = episodePathSegments + [
            destination.workstreamName,
            destination.folderName,
        ]
        var current = root
        for segment in segments {
            try ShotManagerProductionProjection.requireSafeSegment(
                segment, field: "destination segment", allowEmpty: false
            )
            let candidate = current.appendingPathComponent(segment, isDirectory: true)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) {
                let values = try candidate.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                guard isDirectory.boolValue, values.isDirectory == true,
                      values.isSymbolicLink != true else {
                    throw ShotManagerAssociationError.unsafeDestination(
                        "El segmento \(segment) no es un directorio estructural seguro."
                    )
                }
            } else {
                try FileManager.default.createDirectory(
                    at: candidate, withIntermediateDirectories: false
                )
            }
            let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
            guard isDescendant(resolved, of: root) else {
                throw ShotManagerAssociationError.unsafeDestination(
                    "La ruta asociada sale de la raíz de Producción."
                )
            }
            current = resolved
        }
        return .init(
            directoryPath: current.path,
            outputBaseName: "\(canonicalName)\(destination.folderSuffix)_\(String(sceneOrdinal).leftPadding(toLength: 3, withPad: "0"))"
        )
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }
}

private extension String {
    func leftPadding(toLength: Int, withPad pad: Character) -> String {
        guard count < toLength else { return self }
        return String(repeating: String(pad), count: toLength - count) + self
    }
}
