import Foundation

/// Detects an uninitialized collection without opening or choosing another schema.
enum WorkstationDocumentPresence {
    static func requireUninitialized(currentURL: URL, family: String) throws {
        let directory = currentURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let others = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).map(\.lastPathComponent).filter {
            $0.hasPrefix("\(family).v") && $0.hasSuffix(".json")
                && $0 != currentURL.lastPathComponent
        }.sorted()
        guard others.isEmpty else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [
                NSLocalizedDescriptionKey:
                    "Falta \(currentURL.lastPathComponent), pero existen \(others.joined(separator: ", ")). Ejecuta el mantenimiento explícito antes de abrir esta colección.",
                NSFilePathErrorKey: directory.path,
            ])
        }
    }
}
