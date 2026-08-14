import AppKit
import SwiftUI

@MainActor
final class ReferenceMatchPanelController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isVisible = false
    private var panel: NSPanel?
    private weak var activeModel: WorkspaceModel?

    func toggle(model: WorkspaceModel, undoManager: UndoManager?) {
        if let panel, panel.isVisible {
            model.setReferenceMatchEnabled(false)
            panel.orderOut(nil)
            isVisible = false
            return
        }
        show(model: model, undoManager: undoManager)
    }

    func hide(model: WorkspaceModel) {
        model.setReferenceMatchEnabled(false)
        panel?.orderOut(nil)
        isVisible = false
    }

    private func show(model: WorkspaceModel, undoManager: UndoManager?) {
        activeModel = model
        model.setReferenceMatchEnabled(true)
        let content = ReferenceMatchPanel(
            model: model,
            undoManager: undoManager
        )
        if let panel {
            panel.contentView = NSHostingView(rootView: content)
            panel.makeKeyAndOrderFront(nil)
            isVisible = true
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 250),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Match Reference"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: content)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        isVisible = true
    }

    func windowWillClose(_ notification: Notification) {
        activeModel?.setReferenceMatchEnabled(false)
        isVisible = false
    }
}

private struct ReferenceMatchPanel: View {
    @ObservedObject var model: WorkspaceModel
    let undoManager: UndoManager?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(
                    "4 objetivos directos",
                    systemImage: model.referenceMatchCorners.count == 4
                        ? "checkmark.circle.fill" : "circle.dashed"
                )
                .foregroundStyle(model.referenceMatchCorners.count == 4
                    ? .green : .secondary)
                Spacer()
                if let error = model.referenceMatchErrorPixels {
                    Text("Máx. ±\(error.formatted(.number.precision(.fractionLength(1)))) px")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Text("Arrastra directamente los cuatro objetivos amarillos hasta las esquinas del área activa. Al soltar, la cámara se resuelve sin deformar el Device.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Resolver") {
                    model.solveReferenceMatchTargets(undoManager: undoManager)
                }
                Button("Buscar focal") {
                    model.searchReferenceMatchFocalLength(undoManager: undoManager)
                }
                .buttonStyle(.borderedProminent)
            }
            .disabled(!model.referenceMatchEnabled
                || model.referenceMatchCorners.count != 4)

            HStack {
                Button("Reiniciar objetivos") {
                    model.clearReferenceMatchTargets()
                }
                .disabled(model.referenceMatchCorners.count != 4)
                Spacer()
                if let focal = model.referenceMatchFocalLengthMillimeters {
                    Text("Focal \(focal.formatted(.number.precision(.fractionLength(2)))) mm")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(width: 340)
    }
}
