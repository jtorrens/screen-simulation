import SwiftUI

struct CaptureGeometryLensDetails: View {
    let section: CapturePhysicalSection
    let pipeline: PhysicalPipelineResolvedState?

    var body: some View {
        if let parameters = pipeline?.parameters.scene_geometry_lens {
            switch section {
            case .geometry:
                LabeledContent("Pose cámara", value: "posición + quaternion · constante")
                LabeledContent("Pose pantalla", value: "posición + quaternion · constante")
                Text("El fotograma actual entrega tracks constantes explícitos; STATIC_INPUT no implica motion activo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .lens:
                LabeledContent(
                    "Focal",
                    value: "\(parameters.focal_length_millimeters.formatted()) mm"
                )
                LabeledContent(
                    "Sensor óptico",
                    value: "\(parameters.sensor_width_millimeters.formatted()) × \(parameters.sensor_height_millimeters.formatted()) mm"
                )
                LabeledContent("Diafragma", value: "f/\(parameters.f_stop.formatted())")
                LabeledContent(
                    "Foco",
                    value: "\(parameters.focus_distance_meters.formatted()) m"
                )
            default:
                EmptyView()
            }
        } else {
            Text("Selecciona un Device en General.").foregroundStyle(.secondary)
        }
    }
}
