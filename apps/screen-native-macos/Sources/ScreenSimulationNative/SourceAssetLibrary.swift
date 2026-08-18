import Foundation

struct ManagedSourceAsset: Equatable, Sendable {
    let url: URL
    let originalFileName: String
}

enum SourceAssetLibraryError: LocalizedError {
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case let .unreadable(name): "No se puede leer la fuente ‘\(name)’ seleccionada."
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
        return .init(url: source, originalFileName: source.lastPathComponent)
    }
}
