import Foundation
import ScreenPhysicalBridge

struct CameraProfileDefinition: Codable, Equatable, Identifiable, Sendable {
    struct RasterMode: Codable, Equatable, Identifiable, Sendable {
        var id: String
        var name: String
        var width: UInt32
        var height: UInt32
    }

    var id: String
    var name: String
    var calibration: String
    var sensor: PhysicalPipelineAuthoringState.Sensor
    var computationalCapture: PhysicalPipelineAuthoringState.ComputationalCapture
    var renderingIntent: PhysicalPipelineAuthoringState.CameraRenderingIntent
    var radiometricCalibration: PhysicalPipelineAuthoringState.RadiometricCalibration
    var gateWidthMillimeters: Double
    var gateHeightMillimeters: Double
    var defaultFStop: Double
    var referenceExposureIndex: Double
    var middleGrayIlluminanceSeconds: Double
    var defaultShutterAngleDegrees: Double
    var defaultTemporalSamples: UInt16
    var lensAssociationPolicy: UInt16
    var rasterModes: [RasterMode]
    var defaultRasterModeID: String
    var defaultLensEvaluationModelID: String
    var nativeVFXEncodingID: String?
    var defaultLensID: String
    var compatibleLensIDs: [String]
    var defaultRecordingProfileID: String
    var recommendedRecordingProfileIDs: [String]

    init(seed: CapturePresetDefinition, seedIndex: Int) {
        let raw = seed.parameters
        let rawSensor = raw.sensor
        var sensor = PhysicalPipelineAuthoringState.Sensor()
        sensor.nativeWidth = rawSensor.native_width
        sensor.nativeHeight = rawSensor.native_height
        sensor.bayerPattern = rawSensor.bayer_pattern
        sensor.acescgToSensor = [
            rawSensor.acescg_to_sensor.0, rawSensor.acescg_to_sensor.1,
            rawSensor.acescg_to_sensor.2, rawSensor.acescg_to_sensor.3,
            rawSensor.acescg_to_sensor.4, rawSensor.acescg_to_sensor.5,
            rawSensor.acescg_to_sensor.6, rawSensor.acescg_to_sensor.7,
            rawSensor.acescg_to_sensor.8,
        ].map(Double.init)
        sensor.saturationIlluminanceSeconds = [
            rawSensor.saturation_illuminance_seconds.0,
            rawSensor.saturation_illuminance_seconds.1,
            rawSensor.saturation_illuminance_seconds.2,
        ].map(Double.init)
        sensor.fullWellElectrons = Double(rawSensor.full_well_electrons)
        sensor.darkCurrentElectronsPerSecond = Double(rawSensor.dark_current_electrons_per_second)
        sensor.readNoiseElectronsRMS = Double(rawSensor.read_noise_electrons_rms)
        sensor.analogGain = Double(rawSensor.analog_gain)
        sensor.adcBits = rawSensor.adc_bits
        sensor.bloomCharacterStrength = Double(rawSensor.bloom_character_strength)
        sensor.bloomCrosstalkFraction = Double(rawSensor.bloom_crosstalk_fraction)
        sensor.bloomOverflowTransferFraction = Double(rawSensor.bloom_overflow_transfer_fraction)

        self.id = seed.id
        name = seed.name
        calibration = seed.calibration
        self.sensor = sensor
        computationalCapture = .init(
            exposureCount: raw.computational_capture.exposure_count,
            bracketSpacingStops: Double(raw.computational_capture.bracket_spacing_stops)
        )
        renderingIntent = .init(
            exposureEV: Double(raw.camera_rendering_intent.exposure_ev),
            contrast: Double(raw.camera_rendering_intent.contrast),
            saturation: Double(raw.camera_rendering_intent.saturation),
            temperatureKelvin: Double(raw.camera_rendering_intent.temperature_kelvin),
            tint: Double(raw.camera_rendering_intent.tint)
        )
        radiometricCalibration = .init(
            baseExposureIndex: Double(raw.radiometric_calibration.base_exposure_index),
            referenceLambertianReflectance: Double(raw.radiometric_calibration.reference_lambertian_reflectance),
            referenceIlluminanceLux: Double(raw.radiometric_calibration.reference_illuminance_lux),
            referenceTStop: Double(raw.radiometric_calibration.reference_t_stop),
            referenceShutterSeconds: Double(raw.radiometric_calibration.reference_shutter_seconds),
            effectiveSensorExposureScale: Double(raw.radiometric_calibration.effective_sensor_exposure_scale)
        )
        gateWidthMillimeters = Double(raw.gate_width_millimeters)
        gateHeightMillimeters = Double(raw.gate_height_millimeters)
        defaultFStop = Double(raw.default_f_stop)
        referenceExposureIndex = Double(raw.reference_exposure_index)
        middleGrayIlluminanceSeconds = Double(raw.middle_gray_illuminance_seconds)
        defaultShutterAngleDegrees = Double(raw.default_shutter_angle_degrees)
        defaultTemporalSamples = raw.default_temporal_samples
        lensAssociationPolicy = raw.lens_association_policy
        rasterModes = seed.rasterModes.map {
            .init(id: $0.id, name: $0.name, width: $0.width, height: $0.height)
        }
        defaultRasterModeID = seed.defaultRasterModeID
        defaultLensEvaluationModelID = seed.defaultLensEvaluationModelID
        nativeVFXEncodingID = seed.nativeVFXEncodingID
        defaultLensID = seed.defaultLensID
        compatibleLensIDs = seed.compatibleLensIDs
        defaultRecordingProfileID = Self.text(
            screen_capture_preset_default_recording_profile_id(seedIndex)
        )
        recommendedRecordingProfileIDs = (0..<screen_capture_preset_recommended_recording_profile_count(seedIndex)).map {
            Self.text(screen_capture_preset_recommended_recording_profile_id(seedIndex, $0))
        }
    }

    func validate() throws {
        guard !id.isEmpty, !name.isEmpty, rasterModes.count == 3,
              Set(rasterModes.map(\.id)).count == rasterModes.count,
              rasterModes.allSatisfy({ !$0.id.isEmpty && $0.width > 0 && $0.height > 0 }),
              rasterModes.contains(where: { $0.id == defaultRasterModeID }),
              compatibleLensIDs.contains(defaultLensID), !defaultRecordingProfileID.isEmpty,
              gateWidthMillimeters.isFinite, gateWidthMillimeters > 0,
              gateHeightMillimeters.isFinite, gateHeightMillimeters > 0,
              defaultFStop.isFinite, defaultFStop > 0,
              defaultShutterAngleDegrees.isFinite,
              defaultTemporalSamples > 0,
              defaultLensEvaluationModelID == "vfx-2d-dof"
        else { throw GlobalLibraryError.invalidEntity("El perfil de cámara \(name) no es válido.") }
    }

    func applyCamera(
        rasterModeID: String,
        to state: inout PhysicalPipelineAuthoringState,
        frameRate: Double
    ) throws {
        guard let raster = rasterModes.first(where: { $0.id == rasterModeID }) else {
            throw CapturePresetError.invalidRasterMode(rasterModeID)
        }
        state.sceneLens.sensorWidthMillimeters = gateWidthMillimeters
        state.sceneLens.sensorHeightMillimeters = gateHeightMillimeters
        state.sceneLens.fStop = defaultFStop
        state.sceneLens.evaluationModel = defaultLensEvaluationModelID
        state.sensor = sensor
        state.sensor.nativeWidth = raster.width
        state.sensor.nativeHeight = raster.height
        state.computationalCapture = computationalCapture
        state.cameraRenderingIntent = renderingIntent
        state.radiometricCalibration = radiometricCalibration
        state.develop.middleGrayIlluminanceSeconds = middleGrayIlluminanceSeconds
        state.shutterMotion.temporalSamples = defaultTemporalSamples
        let seconds = defaultShutterAngleDegrees / 360 / max(frameRate, 1)
        let halfNanoseconds = Int64((seconds * 0.5 * 1_000_000_000).rounded())
        state.shutterMotion.openOffsetNumerator = -halfNanoseconds
        state.shutterMotion.openOffsetDenominator = 1_000_000_000
        state.shutterMotion.closeOffsetNumerator = halfNanoseconds
        state.shutterMotion.closeOffsetDenominator = 1_000_000_000
    }

    private static func text(_ view: ScreenUTF8View) -> String {
        guard let bytes = view.bytes, view.count > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: bytes, count: view.count), as: UTF8.self)
    }

    static func builtIns() throws -> [Self] {
        try CapturePresetDefinition.catalog().enumerated().map {
            Self(seed: $0.element, seedIndex: $0.offset)
        }
    }
}

struct LensProfileDefinition: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var authority: UInt32
    var nominalFocalLengthMillimeters: Double
    var radialDistortion: [Double]
    var tangentialDistortion: [Double]
    var longitudinalChromaticMeters: [Double]
    var lateralChromaticScale: [Double]
    var vignettingStrength: Double
    var transmissionRGB: [Double]
    var centerSoftnessMicrometers: Double
    var edgeSoftnessMicrometers: Double
    var veilingGlareFraction: Double

    init(seed: LensPresetDefinition) {
        let p = seed.parameters
        id = seed.id
        name = seed.name
        authority = seed.authority.rawValue
        nominalFocalLengthMillimeters = Double(p.nominal_focal_length_millimeters)
        radialDistortion = [p.radial_distortion.0, p.radial_distortion.1, p.radial_distortion.2].map(Double.init)
        tangentialDistortion = [p.tangential_distortion.0, p.tangential_distortion.1].map(Double.init)
        longitudinalChromaticMeters = [p.longitudinal_chromatic_meters.0, p.longitudinal_chromatic_meters.1, p.longitudinal_chromatic_meters.2].map(Double.init)
        lateralChromaticScale = [p.lateral_chromatic_scale.0, p.lateral_chromatic_scale.1, p.lateral_chromatic_scale.2].map(Double.init)
        vignettingStrength = Double(p.vignetting_strength)
        transmissionRGB = [p.transmission_rgb.0, p.transmission_rgb.1, p.transmission_rgb.2].map(Double.init)
        centerSoftnessMicrometers = Double(p.center_softness_micrometers)
        edgeSoftnessMicrometers = Double(p.edge_softness_micrometers)
        veilingGlareFraction = Double(p.veiling_glare_fraction)
    }

    func validate() throws {
        let values = radialDistortion + tangentialDistortion + longitudinalChromaticMeters
            + lateralChromaticScale + transmissionRGB + [
                nominalFocalLengthMillimeters, vignettingStrength,
                centerSoftnessMicrometers, edgeSoftnessMicrometers, veilingGlareFraction,
            ]
        guard !id.isEmpty, !name.isEmpty, nominalFocalLengthMillimeters > 0,
              radialDistortion.count == 3, tangentialDistortion.count == 2,
              longitudinalChromaticMeters.count == 3, lateralChromaticScale.count == 3,
              transmissionRGB.count == 3, values.allSatisfy(\.isFinite)
        else { throw GlobalLibraryError.invalidEntity("El perfil de lente \(name) no es válido.") }
    }

    func apply(to state: inout PhysicalPipelineAuthoringState) {
        state.sceneLens.focalLengthMillimeters = nominalFocalLengthMillimeters
        state.sceneLens.radialDistortion = radialDistortion
        state.sceneLens.tangentialDistortion = tangentialDistortion
        state.sceneLens.longitudinalChromaticMeters = longitudinalChromaticMeters
        state.sceneLens.lateralChromaticScale = lateralChromaticScale
        state.sceneLens.vignettingStrength = vignettingStrength
        state.sceneLens.transmissionRGB = transmissionRGB
        state.sceneLens.centerSoftnessMicrometers = centerSoftnessMicrometers
        state.sceneLens.edgeSoftnessMicrometers = edgeSoftnessMicrometers
        state.sceneLens.veilingGlareFraction = veilingGlareFraction
    }

    static func builtIns() throws -> [Self] {
        try LensPresetDefinition.catalog().map(Self.init(seed:))
    }
}

struct EnvironmentProfileDefinition: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var environment: PhysicalPipelineAuthoringState.Environment

    init(seed: EnvironmentPresetDefinition) {
        id = seed.id
        name = seed.name
        var value = PhysicalPipelineAuthoringState.Environment()
        let p = seed.parameters
        value.sourceKind = p.source_kind
        value.sourceUnitRadianceCandelasPerSquareMeter = Double(p.source_unit_radiance_candelas_per_square_meter)
        value.exposureStops = Double(p.exposure_stops)
        value.ambientRadianceACEScg = [p.ambient_radiance_acescg.0, p.ambient_radiance_acescg.1, p.ambient_radiance_acescg.2].map(Double.init)
        value.keyRadianceACEScg = [p.key_radiance_acescg.0, p.key_radiance_acescg.1, p.key_radiance_acescg.2].map(Double.init)
        value.keyDirectionLocal = [p.key_direction_local.0, p.key_direction_local.1, p.key_direction_local.2].map(Double.init)
        value.keyAngularRadiusDegrees = Double(p.key_angular_radius_degrees)
        value.rotationXDegrees = Double(p.rotation_x_degrees)
        value.rotationYDegrees = Double(p.rotation_y_degrees)
        value.pattern = p.pattern
        environment = value
    }

    func validate() throws {
        guard !id.isEmpty, !name.isEmpty, environment.sourceKind == 0,
              environment.ambientRadianceACEScg.count == 3,
              environment.keyRadianceACEScg.count == 3,
              environment.keyDirectionLocal.count == 3,
              (environment.ambientRadianceACEScg + environment.keyRadianceACEScg
                + environment.keyDirectionLocal).allSatisfy(\.isFinite)
        else { throw GlobalLibraryError.invalidEntity("El perfil de entorno \(name) no es válido.") }
    }

    func apply(to state: inout PhysicalPipelineAuthoringState) {
        state.environment = environment
    }

    static func builtIns() throws -> [Self] {
        try EnvironmentPresetDefinition.catalog().map(Self.init(seed:))
    }
}
