import SwiftUI

struct CaptureSensorDevelopDetails: View {
    let section: CapturePhysicalSection
    let pipeline: PhysicalPipelineResolvedState?

    var body: some View {
        if let parameters = pipeline?.parameters {
            switch section {
            case .sensorCFA:
                LabeledContent(
                    "Raster sensor",
                    value: "\(parameters.sensor_noise.native_width) × \(parameters.sensor_noise.native_height)"
                )
                LabeledContent(
                    "Bayer",
                    value: bayerLabel(parameters.sensor_noise.bayer_pattern)
                )
                LabeledContent("ADC", value: "\(parameters.sensor_noise.adc_bits) bit")
            case .noise:
                LabeledContent(
                    "Full well",
                    value: "\(parameters.sensor_noise.full_well_electrons.formatted()) e⁻"
                )
                LabeledContent(
                    "Read noise",
                    value: "\(parameters.sensor_noise.read_noise_electrons_rms.formatted()) e⁻ RMS"
                )
                LabeledContent(
                    "Ganancia",
                    value: parameters.sensor_noise.analog_gain.formatted()
                )
            case .developDemosaic:
                LabeledContent("Demosaic", value: "Edge-directed")
                LabeledContent(
                    "Gris medio",
                    value: parameters.raw_develop.middle_gray_illuminance_seconds.formatted()
                )
                LabeledContent(
                    "Exposición develop",
                    value: "\(parameters.raw_develop.develop_exposure_ev.formatted()) EV"
                )
            default:
                EmptyView()
            }
        } else {
            Text("Selecciona un Device en General.").foregroundStyle(.secondary)
        }
    }

    private func bayerLabel(_ value: UInt32) -> String {
        switch value {
        case 0: "RGGB"
        case 1: "BGGR"
        case 2: "GRBG"
        case 3: "GBRG"
        default: "Inválido"
        }
    }
}
