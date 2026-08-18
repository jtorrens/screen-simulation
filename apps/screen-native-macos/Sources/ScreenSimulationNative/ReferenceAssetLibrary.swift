import Foundation

struct ManagedReferenceAsset: Equatable, Sendable {
    let url: URL
    let originalFileName: String
}

enum ReferenceAssetLibraryError: LocalizedError {
    case unreadable

    var errorDescription: String? {
        switch self {
        case .unreadable: "No se puede leer la referencia seleccionada."
        }
    }
}

enum ReferenceAssetLibrary {
    static func importAsset(from source: URL, libraryRoot: URL? = nil) throws -> ManagedReferenceAsset {
        let data: Data
        do { data = try Data(contentsOf: source, options: .mappedIfSafe) }
        catch { throw ReferenceAssetLibraryError.unreadable }
        guard !data.isEmpty else { throw ReferenceAssetLibraryError.unreadable }
        return .init(url: source, originalFileName: source.lastPathComponent)
    }
}
