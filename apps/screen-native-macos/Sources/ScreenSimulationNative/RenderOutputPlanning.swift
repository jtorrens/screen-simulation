import Foundation
import StudioMedia

enum RenderOutputPlanningError: Error, LocalizedError, Equatable {
    case invalidJobName
    case selectedDirectoryRequired
    case destinationExists(URL)
    case generatedFileExists(URL)

    var errorDescription: String? {
        switch self {
        case .invalidJobName:
            "El nombre del trabajo no es un componente de ruta válido."
        case .selectedDirectoryRequired:
            "Esta salida requiere seleccionar un directorio."
        case let .destinationExists(url):
            "El destino ya existe: \(url.lastPathComponent)"
        case let .generatedFileExists(url):
            "El archivo generado ya existe: \(url.lastPathComponent)"
        }
    }
}

enum RenderOutputCollision: Equatable, Sendable {
    case none
    case singleFile(URL)
    case populatedDirectory(URL, matchingGeneratedFiles: Int, totalEntries: Int)

    var requiresConfirmation: Bool {
        self != .none
    }
}

struct RenderOutputPlan: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case singleFile
        case imageSequence
        case fusionScenePackage
    }

    let kind: Kind
    /// Exact file for a single-file job, or the job-owned directory for a multi-file job.
    let destination: URL
    let generatedRelativePaths: [String]

    static func prepare(
        configuration: StudioResolvedRenderConfiguration,
        selectedDestination: URL
    ) throws -> Self {
        try configuration.validate()
        try validateJobName(configuration.jobName)
        if configuration.outputType == .fusionScenePackage {
            let packageName = "\(configuration.jobName)_FusionScene"
            let destination = selectedDestination.appendingPathComponent(
                packageName, isDirectory: true
            )
            var relative = configuration.frameRange.map { frame in
                String(format: "media/%@.%08d.exr", configuration.jobName, frame)
            }
            relative.append("fusion/\(configuration.jobName).comp")
            relative.append("metadata/\(configuration.jobName)_FusionScene.json")
            return Self(
                kind: .fusionScenePackage,
                destination: destination,
                generatedRelativePaths: relative
            )
        }
        if configuration.format.isMovie {
            let destination = selectedDestination.deletingPathExtension()
                .appendingPathExtension(configuration.format.fileExtension)
            return Self(
                kind: .singleFile,
                destination: destination,
                generatedRelativePaths: [destination.lastPathComponent]
            )
        }
        let destination = selectedDestination.appendingPathComponent(
            configuration.jobName, isDirectory: true
        )
        let relative = configuration.frameRange.map { frame in
            String(
                format: "%@-%08d.%@",
                configuration.jobName,
                frame,
                configuration.format.fileExtension
            )
        }
        return Self(
            kind: .imageSequence,
            destination: destination,
            generatedRelativePaths: relative
        )
    }

    func inspectCollision(fileManager: FileManager = .default) throws -> RenderOutputCollision {
        switch kind {
        case .singleFile:
            return fileManager.fileExists(atPath: destination.path)
                ? .singleFile(destination) : .none
        case .imageSequence, .fusionScenePackage:
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: destination.path, isDirectory: &isDirectory
            ) else { return .none }
            guard isDirectory.boolValue else { return .singleFile(destination) }
            let entries = try fileManager.contentsOfDirectory(
                at: destination,
                includingPropertiesForKeys: nil,
                options: []
            )
            guard !entries.isEmpty else { return .none }
            let matching = generatedRelativePaths.reduce(into: 0) { count, relative in
                if fileManager.fileExists(
                    atPath: destination.appendingPathComponent(relative).path
                ) { count += 1 }
            }
            return .populatedDirectory(
                destination,
                matchingGeneratedFiles: matching,
                totalEntries: entries.count
            )
        }
    }

    func prepareDirectories(fileManager: FileManager = .default) throws {
        switch kind {
        case .singleFile:
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        case .imageSequence:
            try fileManager.createDirectory(
                at: destination, withIntermediateDirectories: true
            )
        case .fusionScenePackage:
            for component in ["media", "fusion", "metadata"] {
                try fileManager.createDirectory(
                    at: destination.appendingPathComponent(component, isDirectory: true),
                    withIntermediateDirectories: true
                )
            }
        }
    }

    func authorizeWrite(
        to url: URL,
        policy: StudioOverwritePolicy,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        guard policy == .replaceGeneratedFiles else {
            throw RenderOutputPlanningError.generatedFileExists(url)
        }
        guard generatedFileURLs.contains(url.standardizedFileURL) else {
            throw RenderOutputPlanningError.generatedFileExists(url)
        }
    }

    var generatedFileURLs: Set<URL> {
        switch kind {
        case .singleFile:
            [destination.standardizedFileURL]
        case .imageSequence, .fusionScenePackage:
            Set(generatedRelativePaths.map {
                destination.appendingPathComponent($0).standardizedFileURL
            })
        }
    }

    private static func validateJobName(_ name: String) throws {
        guard !name.isEmpty,
              name != ".", name != "..",
              name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.contains("/"), !name.contains("\\"), !name.contains(":"),
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw RenderOutputPlanningError.invalidJobName
        }
    }
}
