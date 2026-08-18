import AppKit
import Foundation

/// Workstation-only panel state. Project documents never contain these paths.
@MainActor
enum FileDialogDirectory: String {
    case sourceMedia
    case referenceMedia
    case trackingComposition
    case environment
    case renderOutput
    case frameExport
    case settingsImport
    case libraryTestImage

    private var defaultsKey: String { "ScreenSimulation.FileDialogDirectory.\(rawValue)" }

    var url: URL? {
        guard let path = UserDefaults.standard.string(forKey: defaultsKey) else { return nil }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return directory
    }

    func apply(to panel: NSSavePanel) { panel.directoryURL = url }

    func remember(_ selectedURL: URL) {
        let directory = selectedURL.hasDirectoryPath
            ? selectedURL : selectedURL.deletingLastPathComponent()
        UserDefaults.standard.set(directory.path, forKey: defaultsKey)
    }
}
