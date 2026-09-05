import SwiftUI

enum RestoreConfirmationError: Error {
    case invalidResponse
}

func workstationRestoreDecision(
    for response: NSApplication.ModalResponse
) throws -> WorkstationRestoreDecision {
    switch response {
    case .alertFirstButtonReturn: .cancelled
    case .alertSecondButtonReturn: .confirmed
    default: throw RestoreConfirmationError.invalidResponse
    }
}

@main
struct ScreenSimulationNativeApp: App {
    @NSApplicationDelegateAdaptor(ScreenSimulationAppDelegate.self) private var appDelegate
    @StateObject private var model: WorkspaceModel

    init() {
        do {
            let records = try BackupHubWorkstationRestoreConsumer()
                .processPendingRestores(confirmation: Self.confirmRestore)
            for record in records { Self.presentRestoreOutcome(record) }
        } catch {
            Self.presentRestoreError(error.localizedDescription)
        }
        _model = StateObject(wrappedValue: WorkspaceModel())
    }

    var body: some Scene {
        WindowGroup("SCREEN-SIMULATION") {
            ContentView(model: model)
                .frame(minWidth: 1040, minHeight: 680)
                .task { await model.verifyWIPReviewAvailabilityAtLaunch() }
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
                Button("Keyframe anterior", action: model.seekPreviousSimulationOpacityKeyframe)
                    .keyboardShortcut("j", modifiers: [])
                Button("Keyframe siguiente", action: model.seekNextSimulationOpacityKeyframe)
                    .keyboardShortcut("k", modifiers: [])
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

    private static func confirmRestore(
        _ confirmation: WorkstationRestoreConfirmation
    ) throws -> WorkstationRestoreDecision {
        let summary = confirmation.summary
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "¿Restaurar este backup de SCREEN-SIMULATION?"
        alert.informativeText = """
        Backup: \(formattedDate(summary.createdAt))
        Motivo: \(reasonLabel(summary.reason))
        Instantánea: \(summary.snapshotFormat), esquema \(summary.snapshotSchemaVersion)
        Contenido: \(summary.fileCount) archivos, \(ByteCountFormatter.string(fromByteCount: Int64(summary.totalBytes), countStyle: .file))

        Antes de reemplazar los datos, SCREEN-SIMULATION guardará la versión actual como «Versión anterior a la restauración» para que puedas volver a ella desde Backup Hub.
        """
        alert.addButton(withTitle: "Cancelar")
        alert.buttons.first?.keyEquivalent = "\r"
        alert.buttons.first?.keyEquivalentModifierMask = []
        alert.addButton(withTitle: "Restaurar")
        alert.buttons.last?.hasDestructiveAction = true
        NSApplication.shared.activate(ignoringOtherApps: true)
        return try workstationRestoreDecision(for: alert.runModal())
    }

    private static func presentRestoreOutcome(_ record: WorkstationRestoreRecord) {
        switch record.state {
        case .applied:
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "Restauración completada"
            alert.informativeText = """
            SCREEN-SIMULATION ha restaurado y verificado el backup. La versión reemplazada queda guardada en Backup Hub como «Versión anterior a la restauración».
            """
            alert.addButton(withTitle: "Aceptar")
            NSApplication.shared.activate(ignoringOtherApps: true)
            alert.runModal()
        case .rejected, .failed:
            presentRestoreError(
                "\(record.errorMessage ?? "Error de restore sin detalle.")\n\nCódigo: \(record.errorCode?.rawValue ?? "resultado-inválido"). Los datos actuales se han conservado."
            )
        case .cancelled:
            break
        }
    }

    private static func presentRestoreError(_ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "No se pudo completar la restauración"
        alert.informativeText = detail
        alert.addButton(withTitle: "Aceptar")
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static func formattedDate(_ value: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: value) else { return value }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private static func reasonLabel(_ reason: String) -> String {
        switch reason {
        case "clean-exit": "Cierre correcto"
        case "manual": "Manual"
        case "pre-migration": "Antes de migrar"
        case "pre-restore": "Antes de restaurar"
        default: reason
        }
    }
}
