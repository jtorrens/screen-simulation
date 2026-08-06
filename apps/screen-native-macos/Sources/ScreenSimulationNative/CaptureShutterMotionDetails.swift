import SwiftUI

struct CaptureShutterMotionDetails: View {
    let pipeline: PhysicalPipelineResolvedState?

    var body: some View {
        if let parameters = pipeline?.parameters.shutter_motion {
            LabeledContent("Muestras temporales", value: "\(parameters.temporal_samples)")
            LabeledContent(
                "Obturador",
                value: parameters.readout_kind == 0 ? "Global" : "Rolling"
            )
            LabeledContent(
                "Readout",
                value: "\(parameters.readout_duration_numerator)/\(parameters.readout_duration_denominator) s"
            )
            LabeledContent(
                "ND",
                value: "\(parameters.neutral_density_stops.formatted()) stops"
            )
            Text("La muestra actual es estática y los tracks son constantes; STATIC_INPUT no reclama motion blur animado.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Selecciona un Device en General.").foregroundStyle(.secondary)
        }
    }
}
