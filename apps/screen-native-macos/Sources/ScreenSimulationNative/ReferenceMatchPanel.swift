import AppKit
import SwiftUI

@MainActor
final class ReferenceMatchPanelController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isVisible = false
    private var panel: NSPanel?

    func toggle(model: WorkspaceModel, undoManager: UndoManager?) {
        if let panel, panel.isVisible {
            panel.orderOut(nil)
            isVisible = false
            return
        }
        show(model: model, undoManager: undoManager)
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

    private func show(model: WorkspaceModel, undoManager: UndoManager?) {
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
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: content)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        isVisible = true
    }

    func windowWillClose(_ notification: Notification) {
        isVisible = false
    }
}

private struct ReferenceMatchPanel: View {
    @ObservedObject var model: WorkspaceModel
    let undoManager: UndoManager?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Toggle("Activar Match", isOn: Binding(
                get: { model.referenceMatchEnabled },
                set: { model.setReferenceMatchEnabled($0) }
            ))
            .toggleStyle(.switch)

            HStack {
                Label(
                    "\(model.referenceMatchPinnedIndices.count)/4 objetivos",
                    systemImage: model.referenceMatchPinnedIndices.count == 4
                        ? "checkmark.circle.fill" : "circle.dashed"
                )
                .foregroundStyle(model.referenceMatchPinnedIndices.count == 4
                    ? .green : .secondary)
                Spacer()
                if let error = model.referenceMatchErrorPixels {
                    Text("Máx. ±\(error.formatted(.number.precision(.fractionLength(1)))) px")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Text("Shift+clic fija o libera un objetivo. Arrastra los objetivos verdes hasta las cuatro esquinas del área activa.")
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
                || model.referenceMatchPinnedIndices.count != 4)

            HStack {
                Button("Borrar objetivos", role: .destructive) {
                    model.clearReferenceMatchTargets()
                }
                .disabled(model.referenceMatchPinnedIndices.isEmpty)
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
