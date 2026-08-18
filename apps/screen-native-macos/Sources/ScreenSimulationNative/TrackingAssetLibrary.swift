import Foundation

struct ManagedTrackingAsset: Equatable, Sendable {
    let url: URL
    let originalFileName: String
}

enum TrackingAssetLibrary {
    static func importAsset(from source: URL, libraryRoot: URL? = nil) throws -> ManagedTrackingAsset {
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        guard source.pathExtension.lowercased() == "comp" else {
            throw FusionTrackingError.invalid("La solución debe ser una composición Fusion .comp.")
        }
        guard !data.isEmpty else { throw FusionTrackingError.invalid("La composición Fusion seleccionada está vacía.") }
        return .init(url: source, originalFileName: source.lastPathComponent)
    }
}
