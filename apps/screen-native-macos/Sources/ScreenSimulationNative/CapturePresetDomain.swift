import Foundation
import ScreenPhysicalBridge
import StudioColor

struct CapturePresetDefinition: Identifiable {
    struct RasterMode: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        let width: UInt32
        let height: UInt32
    }

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
    let parameters: ScreenCapturePresetParametersV4
    let rasterModes: [RasterMode]
    let defaultRasterModeID: String
    let defaultLensEvaluationModelID: String
    let nativeVFXEncodingID: String?

    static func catalog() throws -> [Self] {
        try (0..<screen_capture_preset_count()).map { index in
            var parameters = ScreenCapturePresetParametersV4()
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
            let rawModes = parameters.raster_modes
            let rasterModes = [rawModes.0, rawModes.1, rawModes.2].map { mode in
                RasterMode(
                    id: text(mode.id),
                    name: text(mode.label),
                    width: mode.width,
                    height: mode.height
                )
            }
            let defaultRasterModeID = text(parameters.default_raster_mode_id)
            let rawNativeVFXEncodingID = text(parameters.native_vfx_encoding_id)
            let nativeVFXEncodingID = rawNativeVFXEncodingID.isEmpty
                ? nil : rawNativeVFXEncodingID
            let defaultLensEvaluationModelID = switch parameters.default_lens_evaluation_model {
            case 0: "thin-lens"
            case 1: "vfx-2d-dof"
            default: ""
            }
            guard !compatibleLensIDs.isEmpty,
                  compatibleLensIDs.contains(defaultLensID),
                  Set(rasterModes.map(\.id)).count == rasterModes.count,
                  rasterModes.allSatisfy({ !$0.id.isEmpty && $0.width > 0 && $0.height > 0 }),
                  rasterModes.contains(where: { $0.id == defaultRasterModeID }),
                  !defaultLensEvaluationModelID.isEmpty,
                  nativeVFXEncodingID == nil || StudioVFXInterchangeEncoding.catalog.contains(
                      where: { $0.id == nativeVFXEncodingID }
                  )
            else { throw CapturePresetError.invalidCatalog(index) }
            return Self(
                id: text(screen_capture_preset_id(index)),
                name: text(screen_capture_preset_label(index)),
                calibration: text(screen_capture_preset_calibration(index)),
                defaultLensID: defaultLensID,
                compatibleLensIDs: compatibleLensIDs,
                lensAssociationPolicy: policy,
                parameters: parameters,
                rasterModes: rasterModes,
                defaultRasterModeID: defaultRasterModeID,
                defaultLensEvaluationModelID: defaultLensEvaluationModelID,
                nativeVFXEncodingID: nativeVFXEncodingID
            )
        }
    }

    func applyCamera(
        rasterModeID: String,
        to state: inout PhysicalPipelineAuthoringState,
        frameRate: Double
    ) throws {
        guard let rasterMode = rasterModes.first(where: { $0.id == rasterModeID }) else {
            throw CapturePresetError.invalidRasterMode(rasterModeID)
        }
        let sensor = parameters.sensor
        state.sceneLens.sensorWidthMillimeters = Double(parameters.gate_width_millimeters)
        state.sceneLens.sensorHeightMillimeters = Double(parameters.gate_height_millimeters)
        state.sceneLens.fStop = Double(parameters.default_f_stop)
        state.sceneLens.evaluationModel = defaultLensEvaluationModelID
        state.sensor.nativeWidth = rasterMode.width
        state.sensor.nativeHeight = rasterMode.height
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
        state.computationalCapture = .init(
            exposureCount: parameters.computational_capture.exposure_count,
            bracketSpacingStops: Double(parameters.computational_capture.bracket_spacing_stops)
        )
        let intent = parameters.camera_rendering_intent
        state.cameraRenderingIntent = .init(
            exposureEV: Double(intent.exposure_ev),
            contrast: Double(intent.contrast),
            saturation: Double(intent.saturation),
            temperatureKelvin: Double(intent.temperature_kelvin),
            tint: Double(intent.tint)
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
    case invalidRasterMode(String)
}
