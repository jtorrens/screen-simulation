import SwiftUI

struct PhysicalDiagnosticsView: View {
    let diagnostics: [PhysicalStageDiagnostic]

    var body: some View {
        if diagnostics.isEmpty {
            Text("Se publicará STATIC_INPUT y los tiempos de los grupos fusionados tras la evaluación.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(diagnostics, id: \.stage.id) { diagnostic in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(diagnostic.stage.diagnosticLabel)
                        Spacer()
                        Text(diagnostic.state.diagnosticLabel)
                            .foregroundStyle(.secondary)
                    }
                    if !diagnostic.message.isEmpty {
                        Text(diagnostic.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            Divider()
            LabeledContent(
                "Grupo físico fusionado",
                value: elapsedLabel(diagnostics.first?.elapsedNanoseconds)
            )
            LabeledContent(
                "Grupo sensor/develop fusionado",
                value: elapsedLabel(diagnostics.last?.elapsedNanoseconds)
            )
            Text("Las etapas de un mismo kernel muestran el tiempo medido del grupo; no se inventa un reparto por shader.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func elapsedLabel(_ nanoseconds: UInt64?) -> String {
        guard let nanoseconds, nanoseconds > 0 else { return "—" }
        return "\((Double(nanoseconds) / 1_000_000).formatted(.number.precision(.fractionLength(2)))) ms"
    }
}

private extension PhysicalStageID {
    var diagnosticLabel: String {
        switch self {
        case let .screen(section): section.diagnosticLabel
        case let .capture(section): section.diagnosticLabel
        }
    }
}

private extension ScreenPhysicalSection {
    var diagnosticLabel: String {
        switch self {
        case .emission: "Emission"
        case .subpixelGeometry: "Subpixel"
        case .panelLightSpread: "Panel Light Spread"
        case .temporal: "Temporal"
        case .coverGlass: "Glass"
        case .environment: "Environment"
        }
    }
}

private extension CapturePhysicalSection {
    var diagnosticLabel: String {
        switch self {
        case .geometry: "Geometry"
        case .lens: "Lens"
        case .exposureShutter: "Shutter / Motion"
        case .sensorCFA: "Sensor / CFA"
        case .noise: "Noise"
        case .developDemosaic: "RAW / Develop"
        }
    }
}

private extension PhysicalFrameState {
    var diagnosticLabel: String {
        switch self {
        case .idle: "Idle"
        case .stale: "Stale"
        case .rendering: "Rendering"
        case .cancelled: "Cancelled"
        case .failed: "Failed"
        case .complete: "Complete"
        }
    }
}
