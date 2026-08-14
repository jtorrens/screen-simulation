import CryptoKit
import Foundation

struct ManagedSourceAsset: Equatable, Sendable {
    let url: URL
    let originalFileName: String
    let sha256: String
}

enum SourceAssetLibraryError: LocalizedError {
    case unreadable(String)
    case unavailable(String)
    case copyFailed(String)

    var errorDescription: String? {
        switch self {
        case let .unreadable(name): "No se puede leer la fuente ‘\(name)’ seleccionada."
        case let .unavailable(name): "La fuente guardada ‘\(name)’ ya no está disponible."
        case let .copyFailed(message): "No se pudo guardar la fuente: \(message)"
        }
    }
}

enum SourceAssetLibrary {
    static func importAsset(
        from source: URL,
        libraryRoot: URL? = nil
    ) throws -> ManagedSourceAsset {
        let data: Data
        do { data = try Data(contentsOf: source, options: .mappedIfSafe) }
        catch { throw SourceAssetLibraryError.unreadable(source.lastPathComponent) }
        guard !data.isEmpty else {
            throw SourceAssetLibraryError.unreadable(source.lastPathComponent)
        }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let existing = try asset(
            sha256: hash,
            originalFileName: source.lastPathComponent,
            libraryRoot: libraryRoot
        ) { return existing }
        let directory = try sourceDirectory(libraryRoot: libraryRoot)
        let stem = source.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let suffix = source.pathExtension.isEmpty ? "bin" : source.pathExtension.lowercased()
        let destination = directory.appendingPathComponent("\(stem)--\(hash).\(suffix)")
        do { try data.write(to: destination, options: .atomic) }
        catch { throw SourceAssetLibraryError.copyFailed(error.localizedDescription) }
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
    ) throws -> ManagedSourceAsset? {
        guard sha256.count == 64, sha256.allSatisfy(\.isHexDigit),
              !originalFileName.isEmpty else { return nil }
        let directory = try sourceDirectory(libraryRoot: libraryRoot)
        let candidates = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        guard let url = candidates.first(where: {
            $0.deletingPathExtension().lastPathComponent.hasSuffix("--\(sha256)")
        }) else { return nil }
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { return nil }
        let actualHash = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard actualHash == sha256.lowercased() else { return nil }
        return .init(url: url, originalFileName: originalFileName, sha256: sha256)
    }

    static func sourceDirectory(libraryRoot: URL? = nil) throws -> URL {
        let root = try libraryRoot ?? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = root
            .appendingPathComponent("SCREEN-SIMULATION", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Sources", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }
}
