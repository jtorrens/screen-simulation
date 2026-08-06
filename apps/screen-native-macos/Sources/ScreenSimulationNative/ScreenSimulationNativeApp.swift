import SwiftUI

@main
struct ScreenSimulationNativeApp: App {
    @StateObject private var model = WorkspaceModel()

    var body: some Scene {
        WindowGroup("SCREEN-SIMULATION") {
            ContentView(model: model)
                .frame(minWidth: 1040, minHeight: 680)
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Abrir medio…", action: model.openMedia)
                    .keyboardShortcut("o")
            }
        }
    }
}

