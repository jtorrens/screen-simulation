import Foundation
import StudioMedia

enum RenderOutputPlanningError: Error, LocalizedError, Equatable {
    case invalidJobName
    case selectedDirectoryRequired
    case destinationExists(URL)
    case generatedFileExists(URL)
    case noAvailableVersion

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
        case .noAvailableVersion:
            "No queda una versión disponible entre v002 y v9999."
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

struct RenderOutputPlan: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case singleFile
        case imageSequence
        case deviceSpillDelivery
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
            let mediaNames: [String]
            if configuration.format.isMovie {
                mediaNames = [
                    "media/\(configuration.jobName)_Device.\(configuration.format.fileExtension)",
                    "media/\(configuration.jobName)_Spill.\(configuration.format.fileExtension)"
                ]
            } else {
                mediaNames = configuration.frameRange.flatMap { frame in
                    [
                        String(format: "media/%@_Device.%08d.%@", configuration.jobName, frame, configuration.format.fileExtension),
                        String(format: "media/%@_Spill.%08d.%@", configuration.jobName, frame, configuration.format.fileExtension)
                    ]
                }
            }
            var relative = mediaNames
            relative.append("fusion/\(configuration.jobName).comp")
            relative.append("metadata/\(configuration.jobName)_FusionScene.json")
            return Self(
                kind: .fusionScenePackage,
                destination: destination,
                generatedRelativePaths: relative
            )
        }
        if configuration.composition == .deviceAndSpillSeparate {
            let destination = selectedDestination.appendingPathComponent(
                "\(configuration.jobName)_DeviceSpill", isDirectory: true
            )
            let relative: [String]
            if configuration.format.isMovie {
                relative = [
                    "\(configuration.jobName)_Device.\(configuration.format.fileExtension)",
                    "\(configuration.jobName)_Spill.\(configuration.format.fileExtension)"
                ]
            } else {
                relative = configuration.frameRange.flatMap { frame in
                    [
                        String(format: "%@_Device.%08d.%@", configuration.jobName, frame, configuration.format.fileExtension),
                        String(format: "%@_Spill.%08d.%@", configuration.jobName, frame, configuration.format.fileExtension)
                    ]
                }
            }
            return Self(
                kind: .deviceSpillDelivery,
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
        case .imageSequence, .deviceSpillDelivery, .fusionScenePackage:
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(
                atPath: destination.path, isDirectory: &isDirectory
            ) else { return .none }
            guard isDirectory.boolValue else { return .singleFile(destination) }
            guard let enumerator = fileManager.enumerator(
                at: destination,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: []
            ) else { return .none }
            var fileCount = 0
            for case let entry as URL in enumerator {
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey])
                if values.isDirectory != true { fileCount += 1 }
            }
            guard fileCount > 0 else { return .none }
            let matching = generatedRelativePaths.reduce(into: 0) { count, relative in
                if fileManager.fileExists(
                    atPath: destination.appendingPathComponent(relative).path
                ) { count += 1 }
            }
            return .populatedDirectory(
                destination,
                matchingGeneratedFiles: matching,
                totalEntries: fileCount
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
        case .imageSequence, .deviceSpillDelivery:
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
        case .imageSequence, .deviceSpillDelivery, .fusionScenePackage:
            Set(generatedRelativePaths.map {
                destination.appendingPathComponent($0).standardizedFileURL
            })
        }
    }

    func addingGeneratedRelativePath(_ relativePath: String) throws -> Self {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..")
        else { throw RenderOutputPlanningError.invalidJobName }
        return Self(
            kind: kind,
            destination: destination,
            generatedRelativePaths: generatedRelativePaths + [relativePath]
        )
    }

    /// Allocates one coherent version for every artifact in the deliverable.
    /// The unsuffixed plan is logical v001; version allocation starts at v002.
    func nextAvailableVersion(
        configuration: StudioResolvedRenderConfiguration,
        fileManager: FileManager = .default
    ) throws -> (configuration: StudioResolvedRenderConfiguration, plan: Self) {
        let jobIdentity = Self.versionIdentity(configuration.jobName)
        let firstVersion = max(2, (jobIdentity.version ?? 1) + 1)
        guard firstVersion <= 9_999 else {
            throw RenderOutputPlanningError.noAvailableVersion
        }
        for version in firstVersion ... 9_999 {
            let suffix = String(format: "_v%03d", version)
            let candidateConfiguration = configuration.replacingJobName(
                jobIdentity.base + suffix
            )
            let candidate: Self
            switch kind {
            case .singleFile:
                let ext = destination.pathExtension
                let stem = Self.versionIdentity(
                    destination.deletingPathExtension().lastPathComponent
                ).base
                let parent = destination.deletingLastPathComponent()
                let url = parent.appendingPathComponent(stem + suffix)
                    .appendingPathExtension(ext)
                candidate = Self(
                    kind: .singleFile,
                    destination: url,
                    generatedRelativePaths: [url.lastPathComponent]
                )
            case .imageSequence, .deviceSpillDelivery, .fusionScenePackage:
                candidate = try Self.prepare(
                    configuration: candidateConfiguration,
                    selectedDestination: destination.deletingLastPathComponent()
                )
            }
            if try candidate.inspectCollision(fileManager: fileManager) == .none {
                return (candidateConfiguration, candidate)
            }
        }
        throw RenderOutputPlanningError.noAvailableVersion
    }

    private static func versionIdentity(
        _ value: String
    ) -> (base: String, version: Int?) {
        guard let marker = value.range(of: "_v", options: .backwards) else {
            return (value, nil)
        }
        let digits = value[marker.upperBound...]
        guard (3 ... 4).contains(digits.count),
              digits.allSatisfy(\.isNumber),
              let version = Int(digits), version >= 2 else {
            return (value, nil)
        }
        return (String(value[..<marker.lowerBound]), version)
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
