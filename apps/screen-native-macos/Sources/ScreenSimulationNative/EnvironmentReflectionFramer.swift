import AppKit
import SwiftUI

struct EnvironmentReflectionFraming: Equatable, Sendable {
    var centerX = 0.5
    var centerY = 0.5
    var zoom = 1.0
    var rollDegrees = 0.0

    var shaderValue: SIMD4<Float> {
        SIMD4(Float(centerX), Float(centerY), Float(zoom), Float(rollDegrees * .pi / 180))
    }

    static func capturesViewerNavigation(
        enabled: Bool,
        transformationsLocked: Bool,
        referenceMatchEnabled: Bool,
        reflectionEditorEnabled: Bool
    ) -> Bool {
        enabled
            && !transformationsLocked
            && !referenceMatchEnabled
            && !reflectionEditorEnabled
    }
}

@MainActor
final class EnvironmentReflectionFramingPanelController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isVisible = false
    private var panel: NSPanel?
    private weak var model: WorkspaceModel?

    func toggle(model: WorkspaceModel) {
        if panel?.isVisible == true { hide(model: model); return }
        self.model = model
        model.setEnvironmentReflectionFramingEnabled(true)
        let content = EnvironmentReflectionFramingPanel(model: model)
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 370, height: 300),
                styleMask: [.titled, .closable, .utilityWindow],
                backing: .buffered, defer: false
            )
            panel.title = "Encuadrar reflejo"
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.center()
            self.panel = panel
        }
        panel?.contentView = NSHostingView(rootView: content)
        panel?.makeKeyAndOrderFront(nil)
        isVisible = true
    }

    func hide(model: WorkspaceModel) {
        model.setEnvironmentReflectionFramingEnabled(false)
        panel?.orderOut(nil)
        isVisible = false
    }

    func windowWillClose(_ notification: Notification) {
        model?.setEnvironmentReflectionFramingEnabled(false)
        isVisible = false
    }
}

private struct EnvironmentReflectionFramingPanel: View {
    @ObservedObject var model: WorkspaceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Encuadra una zona del HDRI en plano sobre el Device. Aplicar conserva el HDRI original y deriva una colocación esférica fija en la escena para este frame.")
                .font(.caption).foregroundStyle(.secondary)
            if model.environmentReflectionFramingEnabled {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 9) {
                    row("Centro X", value: model.environmentReflectionFraming.centerX, range: 0 ... 1) {
                        model.updateEnvironmentReflectionFraming(centerX: $0)
                    }
                    row("Centro Y", value: model.environmentReflectionFraming.centerY, range: 0 ... 1) {
                        model.updateEnvironmentReflectionFraming(centerY: $0)
                    }
                    logarithmicScaleRow("Zoom", value: model.environmentReflectionFraming.zoom) {
                        model.updateEnvironmentReflectionFraming(zoom: $0)
                    }
                    row("Rotación Z", value: model.environmentReflectionFraming.rollDegrees, range: -180 ... 180) {
                        model.updateEnvironmentReflectionFraming(rollDegrees: $0)
                    }
                }
                Text("MMB: desplazar · Alt+MMB: rotar Z · Shift+MMB: zoom")
                    .font(.caption2).foregroundStyle(.secondary)
                HStack {
                    Button("Restablecer") { model.resetEnvironmentReflectionFraming() }
                    Spacer()
                    Button("Aplicar colocación") {
                        model.applyEnvironmentReflectionFraming()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Text("La colocación esférica está activa y el HDRI original permanece sin modificar.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Volver a encuadrar") {
                    model.setEnvironmentReflectionFramingEnabled(true)
                }
            }
        }
        .padding(16)
        .frame(width: 370)
    }

    private func row(
        _ label: String, value: Double, range: ClosedRange<Double>,
        update: @escaping (Double) -> Void
    ) -> some View {
        let binding = Binding(
            get: { value },
            set: { update(min(range.upperBound, max(range.lowerBound, $0))) }
        )
        return GridRow {
            Text(label)
            Slider(value: binding, in: range)
            TextField(label, value: binding, format: .number.precision(.fractionLength(0 ... 3)))
                .textFieldStyle(.roundedBorder).frame(width: 74).monospacedDigit()
        }
    }

    private func logarithmicScaleRow(
        _ label: String, value: Double, update: @escaping (Double) -> Void
    ) -> some View {
        let exponentRange = -16.0 ... 16.0
        let valueRange = (1.0 / 65_536.0) ... 65_536.0
        let exponent = Binding(
            get: { log2(min(valueRange.upperBound, max(valueRange.lowerBound, value))) },
            set: { update(exp2(min(exponentRange.upperBound, max(exponentRange.lowerBound, $0)))) }
        )
        let numeric = Binding(
            get: { value },
            set: { update(min(valueRange.upperBound, max(valueRange.lowerBound, $0))) }
        )
        return GridRow {
            Text(label)
            Slider(value: exponent, in: exponentRange)
            TextField(label, value: numeric, format: .number.precision(.fractionLength(0 ... 6)))
                .textFieldStyle(.roundedBorder).frame(width: 74).monospacedDigit()
        }
    }
}
