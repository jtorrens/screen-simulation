import Foundation
import ScreenPhysicalBridge

struct CapturePresetDefinition: Identifiable {
    enum LensAssociationPolicy: UInt16 {
        case interchangeable = 0
        case fixed = 1
    }

    let id: String
    let name: String
    let calibration: String
    let defaultLensID: String
    let compatibleLensIDs: [String]
    let lensAssociationPolicy: LensAssociationPolicy
    let parameters: ScreenCapturePresetParametersV1

    static func catalog() throws -> [Self] {
        try (0..<screen_capture_preset_count()).map { index in
            var parameters = ScreenCapturePresetParametersV1()
            guard screen_capture_preset_parameters(index, &parameters),
                  parameters.abi_version == SCREEN_AUTHORING_CATALOG_ABI_VERSION,
                  let policy = LensAssociationPolicy(
                    rawValue: parameters.lens_association_policy
                  )
            else { throw CapturePresetError.invalidCatalog(index) }
            let compatibleLensIDs = (0..<screen_capture_preset_compatible_lens_count(index)).map {
                text(screen_capture_preset_compatible_lens_id(index, $0))
            }
            let defaultLensID = text(screen_capture_preset_default_lens_id(index))
            guard !compatibleLensIDs.isEmpty,
                  compatibleLensIDs.contains(defaultLensID)
            else { throw CapturePresetError.invalidCatalog(index) }
            return Self(
                id: text(screen_capture_preset_id(index)),
                name: text(screen_capture_preset_label(index)),
                calibration: text(screen_capture_preset_calibration(index)),
                defaultLensID: defaultLensID,
                compatibleLensIDs: compatibleLensIDs,
                lensAssociationPolicy: policy,
                parameters: parameters
            )
        }
    }

    func applyCamera(to state: inout PhysicalPipelineAuthoringState, frameRate: Double) {
        let sensor = parameters.sensor
        state.sceneLens.sensorWidthMillimeters = Double(parameters.gate_width_millimeters)
        state.sceneLens.sensorHeightMillimeters = Double(parameters.gate_height_millimeters)
        state.sceneLens.fStop = Double(parameters.default_f_stop)
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
        state.sensor.bloomCharacterStrength = Double(sensor.bloom_character_strength)
        state.sensor.bloomCrosstalkFraction = Double(sensor.bloom_crosstalk_fraction)
        state.sensor.bloomOverflowTransferFraction = Double(
            sensor.bloom_overflow_transfer_fraction
        )
        let radiometric = parameters.radiometric_calibration
        state.radiometricCalibration = .init(
            baseExposureIndex: Double(radiometric.base_exposure_index),
            referenceLambertianReflectance: Double(radiometric.reference_lambertian_reflectance),
            referenceIlluminanceLux: Double(radiometric.reference_illuminance_lux),
            referenceTStop: Double(radiometric.reference_t_stop),
            referenceShutterSeconds: Double(radiometric.reference_shutter_seconds),
            effectiveSensorExposureScale: Double(radiometric.effective_sensor_exposure_scale)
        )
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

struct LensPresetDefinition: Identifiable, Equatable, Sendable {
    enum Authority: UInt32 {
        case genericApproximation = 0
        case calibratedApproximation = 1
    }

    let id: String
    let name: String
    let authority: Authority
    let parameters: ScreenLensPresetParametersV1

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id
    }

    static func catalog() throws -> [Self] {
        try (0..<screen_lens_preset_count()).map { index in
            var parameters = ScreenLensPresetParametersV1()
            guard screen_lens_preset_parameters(index, &parameters),
                  parameters.abi_version == SCREEN_AUTHORING_CATALOG_ABI_VERSION,
                  let authority = Authority(rawValue: screen_lens_preset_authority(index))
            else { throw CapturePresetError.invalidLensCatalog(index) }
            return Self(
                id: text(screen_lens_preset_id(index)),
                name: text(screen_lens_preset_label(index)),
                authority: authority,
                parameters: parameters
            )
        }
    }

    func apply(to state: inout PhysicalPipelineAuthoringState) {
        state.sceneLens.focalLengthMillimeters = Double(
            parameters.nominal_focal_length_millimeters
        )
        state.sceneLens.radialDistortion = tuple3(parameters.radial_distortion)
        state.sceneLens.tangentialDistortion = tuple2(parameters.tangential_distortion)
        state.sceneLens.longitudinalChromaticMeters = tuple3(
            parameters.longitudinal_chromatic_meters
        )
        state.sceneLens.lateralChromaticScale = tuple3(parameters.lateral_chromatic_scale)
        state.sceneLens.vignettingStrength = Double(parameters.vignetting_strength)
        state.sceneLens.transmissionRGB = tuple3(parameters.transmission_rgb)
        state.sceneLens.centerSoftnessMicrometers = Double(
            parameters.center_softness_micrometers
        )
        state.sceneLens.edgeSoftnessMicrometers = Double(
            parameters.edge_softness_micrometers
        )
        state.sceneLens.veilingGlareFraction = Double(parameters.veiling_glare_fraction)
    }

    private func tuple3(_ value: (Float, Float, Float)) -> [Double] {
        [Double(value.0), Double(value.1), Double(value.2)]
    }

    private func tuple2(_ value: (Float, Float)) -> [Double] {
        [Double(value.0), Double(value.1)]
    }

    private static func text(_ view: ScreenUTF8View) -> String {
        guard let bytes = view.bytes, view.count > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: view.count), as: UTF8.self)
    }
}

enum CapturePresetError: Error {
    case invalidCatalog(Int)
    case invalidLensCatalog(Int)
}
