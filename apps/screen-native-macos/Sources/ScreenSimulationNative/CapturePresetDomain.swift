import Foundation
import ScreenPhysicalBridge

struct CapturePresetDefinition: Identifiable {
    let id: String
    let name: String
    let calibration: String
    let defaultLensID: String
    let parameters: ScreenCapturePresetParametersV2

    static func catalog() throws -> [Self] {
        try (0..<screen_capture_preset_count()).map { index in
            var parameters = ScreenCapturePresetParametersV2()
            guard screen_capture_preset_parameters(index, &parameters),
                  parameters.abi_version == SCREEN_PHYSICAL_FRAME_ABI_VERSION
            else { throw CapturePresetError.invalidCatalog(index) }
            return Self(
                id: text(screen_capture_preset_id(index)),
                name: text(screen_capture_preset_label(index)),
                calibration: text(screen_capture_preset_calibration(index)),
                defaultLensID: text(screen_capture_preset_default_lens_id(index)),
                parameters: parameters
            )
        }
    }

    func apply(to state: inout PhysicalPipelineAuthoringState, frameRate: Double) {
        let sensor = parameters.sensor
        state.sceneLens.focalLengthMillimeters = Double(parameters.focal_length_millimeters)
        state.sceneLens.sensorWidthMillimeters = Double(parameters.gate_width_millimeters)
        state.sceneLens.sensorHeightMillimeters = Double(parameters.gate_height_millimeters)
        state.sceneLens.fStop = Double(parameters.f_stop)
        state.sensor.nativeWidth = sensor.native_width
        state.sensor.nativeHeight = sensor.native_height
        state.sensor.bayerPattern = sensor.bayer_pattern
        state.sensor.acescgToSensor = [
            sensor.acescg_to_sensor.0, sensor.acescg_to_sensor.1, sensor.acescg_to_sensor.2,
            sensor.acescg_to_sensor.3, sensor.acescg_to_sensor.4, sensor.acescg_to_sensor.5,
            sensor.acescg_to_sensor.6, sensor.acescg_to_sensor.7, sensor.acescg_to_sensor.8,
        ].map(Double.init)
        state.sensor.saturationIlluminanceSeconds = [
            sensor.saturation_illuminance_seconds.0,
            sensor.saturation_illuminance_seconds.1,
            sensor.saturation_illuminance_seconds.2,
        ].map(Double.init)
        state.sensor.fullWellElectrons = Double(sensor.full_well_electrons)
        state.sensor.darkCurrentElectronsPerSecond = Double(sensor.dark_current_electrons_per_second)
        state.sensor.readNoiseElectronsRMS = Double(sensor.read_noise_electrons_rms)
        state.sensor.analogGain = Double(sensor.analog_gain)
        state.sensor.adcBits = sensor.adc_bits
        state.develop.middleGrayIlluminanceSeconds = Double(parameters.middle_gray_illuminance_seconds)
        state.shutterMotion.temporalSamples = parameters.default_temporal_samples
        let fps = max(frameRate, 1)
        let exposureSeconds = Double(parameters.default_shutter_angle_degrees) / 360 / fps
        let halfNanoseconds = Int64((exposureSeconds * 0.5 * 1_000_000_000).rounded())
        state.shutterMotion.openOffsetNumerator = -halfNanoseconds
        state.shutterMotion.openOffsetDenominator = 1_000_000_000
        state.shutterMotion.closeOffsetNumerator = halfNanoseconds
        state.shutterMotion.closeOffsetDenominator = 1_000_000_000
        state.shutterMotion.readoutDurationNumerator = Int64(
            (Double(parameters.default_readout_duration_milliseconds) * 1_000_000).rounded()
        )
        state.shutterMotion.readoutDurationDenominator = 1_000_000_000
    }

    private static func text(_ view: ScreenUTF8View) -> String {
        guard let bytes = view.bytes, view.count > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: view.count), as: UTF8.self)
    }
}

enum CapturePresetError: Error {
    case invalidCatalog(Int)
}
