import CryptoKit
import Foundation

struct ManagedTrackingAsset: Equatable, Sendable {
    let url: URL
    let originalFileName: String
    let sha256: String
}

enum TrackingAssetLibrary {
    static func importAsset(from source: URL, libraryRoot: URL? = nil) throws -> ManagedTrackingAsset {
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard source.pathExtension.lowercased() == "comp" else {
            throw FusionTrackingError.invalid("La solución debe ser una composición Fusion .comp.")
        }
        guard !data.isEmpty else { throw FusionTrackingError.invalid("La composición Fusion seleccionada está vacía.") }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        if let existing = try asset(sha256: hash, originalFileName: source.lastPathComponent, libraryRoot: libraryRoot) {
            return existing
        }
        let directory = try trackingDirectory(libraryRoot: libraryRoot)
        let stem = source.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let destination = directory.appendingPathComponent("\(stem)--\(hash).comp")
        try data.write(to: destination, options: .atomic)
        return .init(url: destination, originalFileName: source.lastPathComponent, sha256: hash)
    }

    static func asset(sha256: String, originalFileName: String, libraryRoot: URL? = nil) throws -> ManagedTrackingAsset? {
        guard sha256.count == 64, sha256.allSatisfy(\.isHexDigit), !originalFileName.isEmpty else { return nil }
        let candidates = try FileManager.default.contentsOfDirectory(
            at: trackingDirectory(libraryRoot: libraryRoot),
            includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
        )
        guard let url = candidates.first(where: {
            $0.deletingPathExtension().lastPathComponent.hasSuffix("--\(sha256)")
        }) else { return nil }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == sha256.lowercased() else { return nil }
        return .init(url: url, originalFileName: originalFileName, sha256: sha256)
    }

    static func trackingDirectory(libraryRoot: URL? = nil) throws -> URL {
        let root = try libraryRoot ?? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let directory = root
            .appendingPathComponent("SCREEN-SIMULATION", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Tracking", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
