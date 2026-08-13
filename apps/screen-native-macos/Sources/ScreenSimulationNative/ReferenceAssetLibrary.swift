import CryptoKit
import Foundation

struct ManagedReferenceAsset: Equatable, Sendable {
    let url: URL
    let originalFileName: String
    let sha256: String
}

enum ReferenceAssetLibraryError: LocalizedError {
    case unreadable
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case .unreadable: "No se puede leer la referencia seleccionada."
        case let .copyFailed(message): "No se pudo guardar la referencia: \(message)"
        }
    }
}

enum ReferenceAssetLibrary {
    static func importAsset(from source: URL, libraryRoot: URL? = nil) throws -> ManagedReferenceAsset {
        let data: Data
        do { data = try Data(contentsOf: source, options: .mappedIfSafe) }
        catch { throw ReferenceAssetLibraryError.unreadable }
        guard !data.isEmpty else { throw ReferenceAssetLibraryError.unreadable }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let existing = try asset(
            sha256: hash, originalFileName: source.lastPathComponent, libraryRoot: libraryRoot
        ) { return existing }
        let directory = try referenceDirectory(libraryRoot: libraryRoot)
        let destination = directory.appendingPathComponent(
            "\(source.deletingPathExtension().lastPathComponent)--\(hash).\(source.pathExtension.lowercased())"
        )
        if !FileManager.default.fileExists(atPath: destination.path) {
            do { try data.write(to: destination, options: .atomic) }
            catch { throw ReferenceAssetLibraryError.copyFailed(error.localizedDescription) }
        }
        return .init(url: destination, originalFileName: source.lastPathComponent, sha256: hash)
    }

    static func asset(
        sha256: String, originalFileName: String, libraryRoot: URL? = nil
    ) throws -> ManagedReferenceAsset? {
        guard sha256.count == 64, sha256.allSatisfy(\.isHexDigit) else { return nil }
        let directory = try referenceDirectory(libraryRoot: libraryRoot)
        let candidates = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )
        guard let url = candidates.first(where: {
            $0.deletingPathExtension().lastPathComponent.hasSuffix("--\(sha256)")
        }) else { return nil }
        return .init(url: url, originalFileName: originalFileName, sha256: sha256)
    }

    static func referenceDirectory(libraryRoot: URL? = nil) throws -> URL {
        let root = try libraryRoot ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let directory = root.appendingPathComponent("SCREEN-SIMULATION", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("References", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
