import CryptoKit
import Foundation

struct ManagedEnvironmentAsset: Equatable, Sendable {
    let url: URL
    let originalFileName: String
    let sha256: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.url.resolvingSymlinksInPath().standardizedFileURL
            == rhs.url.resolvingSymlinksInPath().standardizedFileURL
            && lhs.originalFileName == rhs.originalFileName
            && lhs.sha256 == rhs.sha256
    }
}

struct EnvironmentAssetCalibration: Codable, Equatable, Sendable {
    static let schema = "ScreenSimulation.EnvironmentCalibration.v1"

    let schema: String
    let inputTransformID: String
    let sourceUnitRadianceCandelasPerSquareMeter: Double
    let exposureEV: Double

    init(
        inputTransformID: String,
        sourceUnitRadianceCandelasPerSquareMeter: Double,
        exposureEV: Double
    ) throws {
        guard !inputTransformID.isEmpty,
              sourceUnitRadianceCandelasPerSquareMeter.isFinite,
              sourceUnitRadianceCandelasPerSquareMeter > 0,
              exposureEV.isFinite, (-16 ... 16).contains(exposureEV)
        else { throw EnvironmentAssetLibraryError.invalidCalibration }
        schema = Self.schema
        self.inputTransformID = inputTransformID
        self.sourceUnitRadianceCandelasPerSquareMeter =
            sourceUnitRadianceCandelasPerSquareMeter
        self.exposureEV = exposureEV
    }

    func validate() throws {
        guard schema == Self.schema, !inputTransformID.isEmpty,
              sourceUnitRadianceCandelasPerSquareMeter.isFinite,
              sourceUnitRadianceCandelasPerSquareMeter > 0,
              exposureEV.isFinite, (-16 ... 16).contains(exposureEV)
        else { throw EnvironmentAssetLibraryError.invalidCalibration }
    }
}

enum EnvironmentAssetLibraryError: LocalizedError {
    case unreadable
    case invalidExtension
    case copyFailed(String)
    case invalidCalibration

    var errorDescription: String? {
        switch self {
        case .unreadable: "No se puede leer el entorno seleccionado."
        case .invalidExtension: "El entorno debe ser OpenEXR o Radiance HDR."
        case let .copyFailed(message): "No se pudo guardar el entorno en la biblioteca: \(message)"
        case .invalidCalibration: "La calibración guardada del entorno no es válida."
        }
    }
}

enum EnvironmentAssetLibrary {
    private static let supportedExtensions: Set<String> = ["exr", "hdr"]

    static func importAsset(
        from source: URL,
        libraryRoot: URL? = nil
    ) throws -> ManagedEnvironmentAsset {
        let pathExtension = source.pathExtension.lowercased()
        guard supportedExtensions.contains(pathExtension) else {
            throw EnvironmentAssetLibraryError.invalidExtension
        }
        let data: Data
        do { data = try Data(contentsOf: source, options: .mappedIfSafe) }
        catch { throw EnvironmentAssetLibraryError.unreadable }
        guard !data.isEmpty else { throw EnvironmentAssetLibraryError.unreadable }
        return .init(url: source, originalFileName: source.lastPathComponent, sha256: "")
    }

    static func storeGeneratedEXR(
        _ data: Data,
        suggestedName: String,
        libraryRoot: URL? = nil
    ) throws -> ManagedEnvironmentAsset {
        guard !data.isEmpty else { throw EnvironmentAssetLibraryError.unreadable }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let directory = try environmentDirectory(libraryRoot: libraryRoot)
        let cleanName = suggestedName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let fileName = cleanName == "Reflejos creados"
            ? "working-reflections.exr" : "\(cleanName)--\(hash).exr"
        let destination = directory.appendingPathComponent(fileName)
        do { try data.write(to: destination, options: .atomic) }
        catch { throw EnvironmentAssetLibraryError.copyFailed(error.localizedDescription) }
        return .init(
            url: destination,
            originalFileName: fileName,
            sha256: hash
        )
    }

    static func storeSceneGeneratedEXR(
        _ data: Data,
        sceneID: UUID,
        libraryRoot: URL? = nil
    ) throws -> ManagedEnvironmentAsset {
        guard !data.isEmpty else { throw EnvironmentAssetLibraryError.unreadable }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let fileName = "scene-\(sceneID.uuidString.lowercased()).exr"
        let destination = try environmentDirectory(libraryRoot: libraryRoot)
            .appendingPathComponent(fileName)
        do { try data.write(to: destination, options: .atomic) }
        catch { throw EnvironmentAssetLibraryError.copyFailed(error.localizedDescription) }
        return .init(url: destination, originalFileName: fileName, sha256: hash)
    }

    static func removeSceneGeneratedEXR(
        sceneID: UUID,
        libraryRoot: URL? = nil
    ) throws {
        let fileName = "scene-\(sceneID.uuidString.lowercased()).exr"
        let url = try environmentDirectory(libraryRoot: libraryRoot)
            .appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw EnvironmentAssetLibraryError.unreadable
        }
        do { try FileManager.default.removeItem(at: url) }
        catch { throw EnvironmentAssetLibraryError.copyFailed(error.localizedDescription) }
    }

    static func asset(
        sha256: String,
        originalFileName: String,
        libraryRoot: URL? = nil
    ) throws -> ManagedEnvironmentAsset? {
        guard sha256.count == 64, sha256.allSatisfy(\.isHexDigit) else { return nil }
        let directory = try environmentDirectory(libraryRoot: libraryRoot)
        if originalFileName == "working-reflections.exr"
            || originalFileName.hasPrefix("scene-") {
            let exact = directory.appendingPathComponent(originalFileName)
            guard let data = try? Data(contentsOf: exact, options: .mappedIfSafe) else { return nil }
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard actual == sha256 else { return nil }
            return .init(url: exact, originalFileName: originalFileName, sha256: sha256)
        }
        let candidates = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        if let url = candidates.first(where: {
            supportedExtensions.contains($0.pathExtension.lowercased())
                && $0.deletingPathExtension().lastPathComponent.hasSuffix("--\(sha256)")
        }) {
            return .init(url: url, originalFileName: originalFileName, sha256: sha256)
        }
        return nil
    }

    static func calibration(for asset: ManagedEnvironmentAsset) throws
        -> EnvironmentAssetCalibration?
    {
        let url = calibrationURL(for: asset.url)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any],
              Set(dictionary.keys) == [
                  "schema", "inputTransformID",
                  "sourceUnitRadianceCandelasPerSquareMeter", "exposureEV",
              ]
        else { throw EnvironmentAssetLibraryError.invalidCalibration }
        let value = try JSONDecoder().decode(EnvironmentAssetCalibration.self, from: data)
        try value.validate()
        return value
    }

    static func saveCalibration(
        _ calibration: EnvironmentAssetCalibration,
        for asset: ManagedEnvironmentAsset
    ) throws {
        try calibration.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(calibration).write(
            to: calibrationURL(for: asset.url), options: .atomic
        )
    }

    static func managedAsset(at url: URL) -> ManagedEnvironmentAsset? {
        let stem = url.deletingPathExtension().lastPathComponent
        guard let separator = stem.range(of: "--", options: .backwards) else { return nil }
        let hash = String(stem[separator.upperBound...])
        guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { return nil }
        return .init(url: url, originalFileName: url.lastPathComponent, sha256: hash)
    }

    static func environmentDirectory(libraryRoot: URL? = nil) throws -> URL {
        let root = try libraryRoot ?? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = root
            .appendingPathComponent("SCREEN-SIMULATION", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Environments", isDirectory: true)
            .appendingPathComponent("HDRI", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        return directory
    }

    private static func calibrationURL(for assetURL: URL) -> URL {
        assetURL.deletingPathExtension().appendingPathExtension("environment.json")
    }
}
