import Foundation
import ScreenPhysicalBridge

/// Fully materialized state crossing the physical ABI. Every value is explicit;
/// the engine never resolves a preset or supplies a product default.
struct PhysicalPipelineResolvedState {
    let parameters: ScreenPhysicalPipelineParametersV2
    let coverGlassID: String

    static func resolvedDefaults(
        coverGlass: CoverGlassDefinition
    ) throws -> Self {
        try coverGlass.validate()
        let version = UInt32(SCREEN_PHYSICAL_FRAME_ABI_VERSION)

        var environment = ScreenEnvironmentParametersV2()
        environment.abi_version = version
        environment.character_strength = 0
        environment.ambient_radiance_acescg = (0, 0, 0)
        environment.key_radiance_acescg = (0, 0, 0)
        environment.key_direction_local = (0, 0, 1)
        environment.key_angular_radius_degrees = 20
        environment.rotation_degrees = 0
        environment.pattern = 0

        var scene = ScreenSceneGeometryLensParametersV2()
        scene.abi_version = version
        scene.focal_length_millimeters = 50
        scene.sensor_width_millimeters = 36
        scene.sensor_height_millimeters = 24
        scene.lens_shift = (0, 0)
        scene.focus_distance_meters = 1
        scene.f_stop = 2.8
        scene.near_clip_meters = 0.01
        scene.far_clip_meters = 100
        scene.lens_radial_distortion = (0, 0, 0)
        scene.lens_tangential_distortion = (0, 0)
        scene.lens_longitudinal_chromatic_meters = (0, 0, 0)
        scene.lens_lateral_chromatic_scale = (1, 1, 1)
        scene.lens_vignetting_strength = 0
        scene.lens_transmission_rgb = (1, 1, 1)
        scene.lens_center_softness_micrometers = 0
        scene.lens_edge_softness_micrometers = 0

        var shutter = ScreenShutterMotionParametersV2()
        shutter.abi_version = version
        shutter.temporal_samples = 1
        shutter.readout_kind = 0
        shutter.readout_duration_numerator = 1
        shutter.readout_duration_denominator = 48
        shutter.readout_direction = 0
        shutter.neutral_density_stops = 0
        shutter.noise_seed = 7

        var sensor = ScreenSensorNoiseParametersV2()
        sensor.abi_version = version
        sensor.native_width = 3_840
        sensor.native_height = 2_160
        sensor.bayer_pattern = 0
        sensor.acescg_to_sensor = (
            0.72, 0.21, 0.07,
            0.10, 0.82, 0.08,
            0.03, 0.16, 0.81
        )
        sensor.saturation_illuminance_seconds = (2.4, 2.4, 2.4)
        sensor.full_well_electrons = 45_000
        sensor.dark_current_electrons_per_second = 0.1
        sensor.read_noise_electrons_rms = 2
        sensor.analog_gain = 1
        sensor.adc_bits = 14

        var develop = ScreenRawDevelopParametersV2()
        develop.abi_version = version
        develop.white_balance = (1, 1, 1)
        develop.middle_gray_illuminance_seconds = 0.18
        develop.develop_exposure_ev = 0

        var radiometric = ScreenCameraRadiometricCalibrationV2()
        radiometric.abi_version = version
        radiometric.base_exposure_index = 100
        radiometric.reference_lambertian_reflectance = 0.18
        radiometric.reference_illuminance_lux = 100
        radiometric.reference_t_stop = 4
        radiometric.reference_shutter_seconds = 1.0 / 48.0
        radiometric.effective_sensor_exposure_scale = 1

        var parameters = ScreenPhysicalPipelineParametersV2()
        parameters.abi_version = version
        parameters.cover = try coverGlass.bridgeParameters()
        parameters.environment = environment
        parameters.scene_geometry_lens = scene
        parameters.shutter_motion = shutter
        parameters.sensor_noise = sensor
        parameters.raw_develop = develop
        parameters.radiometric_calibration = radiometric
        return Self(parameters: parameters, coverGlassID: coverGlass.id)
    }

    func resolving(
        contributions: [PhysicalStageContribution],
        focusDistanceMeters: Float? = nil
    ) throws -> Self {
        func amount(_ stage: PhysicalStageID) throws -> Float {
            guard let value = contributions.first(where: { $0.stage == stage })?.amount else {
                throw PhysicalContractError.invalidStageOrder
            }
            return Float(value)
        }
        var resolved = parameters
        resolved.cover.character_strength = try amount(.screen(.coverGlass))
        resolved.environment.character_strength = try amount(.screen(.environment))
        if let focusDistanceMeters {
            guard focusDistanceMeters.isFinite, focusDistanceMeters > 0 else {
                throw DeviceDomainError.invalidPhysicalProfile("Distancia de foco no válida.")
            }
            resolved.scene_geometry_lens.focus_distance_meters = focusDistanceMeters
        }
        return Self(parameters: resolved, coverGlassID: coverGlassID)
    }
}
