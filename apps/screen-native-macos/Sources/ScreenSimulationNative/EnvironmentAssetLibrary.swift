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

enum EnvironmentAssetLibraryError: LocalizedError {
    case unreadable
    case invalidExtension
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: "No se puede leer el entorno seleccionado."
        case .invalidExtension: "El entorno debe ser OpenEXR o Radiance HDR."
        case let .copyFailed(message): "No se pudo guardar el entorno en la biblioteca: \(message)"
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
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let existing = try asset(
            sha256: hash,
            originalFileName: source.lastPathComponent,
            libraryRoot: libraryRoot
        ) {
            return existing
        }
        let directory = try environmentDirectory(libraryRoot: libraryRoot)
        let stem = source.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
        let destination = directory.appendingPathComponent(
            "\(stem)--\(hash).\(pathExtension)"
        )
        if !FileManager.default.fileExists(atPath: destination.path) {
            let temporary = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
            do {
                try data.write(to: temporary, options: .atomic)
                try FileManager.default.moveItem(at: temporary, to: destination)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                throw EnvironmentAssetLibraryError.copyFailed(error.localizedDescription)
            }
        }
        return .init(
            url: destination,
            originalFileName: source.lastPathComponent,
            sha256: hash
        )
    }

    static func asset(
        sha256: String,
        originalFileName: String,
        libraryRoot: URL? = nil
    ) throws -> ManagedEnvironmentAsset? {
        guard sha256.count == 64, sha256.allSatisfy(\.isHexDigit) else { return nil }
        let directory = try environmentDirectory(libraryRoot: libraryRoot)
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
}
