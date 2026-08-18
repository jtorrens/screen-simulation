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
            CommandMenu("Transporte") {
                Button(model.isPlaying ? "Pausa" : "Reproducir", action: model.togglePlayback)
                    .keyboardShortcut(.space, modifiers: [])
                Button("Frame anterior") { model.step(-1) }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("Frame siguiente") { model.step(1) }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Divider()
                Button("Marcar IN", action: model.markIn).keyboardShortcut("i", modifiers: [])
                Button("Marcar OUT", action: model.markOut).keyboardShortcut("o", modifiers: [])
            }
            CommandMenu("Visor") {
                Button("Aumentar zoom") { model.zoomBy(1.25) }.keyboardShortcut("+")
                Button("Reducir zoom") { model.zoomBy(0.8) }.keyboardShortcut("-")
                Button("Ajustar visor", action: model.resetView).keyboardShortcut("0")
            }
        }
    }
}
