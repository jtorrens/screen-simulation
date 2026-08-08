import Foundation
import ScreenPhysicalBridge

/// Project-owned authoring values for the ABI-v2 snapshot. Presets seed this
/// value once; subsequent edits never mutate the global library entity.
struct PhysicalPipelineAuthoringState: Codable, Equatable, Sendable {
    struct Environment: Codable, Equatable, Sendable {
        var ambientRadianceACEScg = [0.0, 0.0, 0.0]
        var keyRadianceACEScg = [0.0, 0.0, 0.0]
        var keyDirectionLocal = [0.0, 0.0, 1.0]
        var keyAngularRadiusDegrees = 20.0
        var rotationDegrees = 0.0
        var pattern: UInt32 = 0
    }

    struct SceneLens: Codable, Equatable, Sendable {
        var focalLengthMillimeters = 50.0
        var sensorWidthMillimeters = 36.0
        var sensorHeightMillimeters = 24.0
        var lensShift = [0.0, 0.0]
        var focusDistanceMeters = 1.0
        var fStop = 2.8
        var nearClipMeters = 0.01
        var farClipMeters = 100.0
        var radialDistortion = [0.0, 0.0, 0.0]
        var tangentialDistortion = [0.0, 0.0]
        var longitudinalChromaticMeters = [0.0, 0.0, 0.0]
        var lateralChromaticScale = [1.0, 1.0, 1.0]
        var vignettingStrength = 0.0
        var transmissionRGB = [1.0, 1.0, 1.0]
        var centerSoftnessMicrometers = 0.0
        var edgeSoftnessMicrometers = 0.0
    }

    struct ShutterMotion: Codable, Equatable, Sendable {
        var temporalSamples: UInt16 = 1
        var readoutKind: UInt16 = 0
        var readoutDurationNumerator: Int64 = 1
        var readoutDurationDenominator: UInt32 = 48
        var readoutDirection: UInt32 = 0
        var neutralDensityStops = 0.0
        var noiseSeed: UInt64 = 7
        var openOffsetNumerator: Int64 = -1
        var openOffsetDenominator: UInt32 = 96
        var closeOffsetNumerator: Int64 = 1
        var closeOffsetDenominator: UInt32 = 96
    }

    struct Sensor: Codable, Equatable, Sendable {
        var nativeWidth: UInt32 = 3_840
        var nativeHeight: UInt32 = 2_160
        var bayerPattern: UInt32 = 0
        var acescgToSensor = [0.72, 0.21, 0.07, 0.10, 0.82, 0.08, 0.03, 0.16, 0.81]
        var saturationIlluminanceSeconds = [2.4, 2.4, 2.4]
        var fullWellElectrons = 45_000.0
        var darkCurrentElectronsPerSecond = 0.1
        var readNoiseElectronsRMS = 2.0
        var analogGain = 1.0
        var adcBits: UInt32 = 14
        var bloomCharacterStrength = 1.0
        var bloomCrosstalkFraction = 0.012
        var bloomOverflowTransferFraction = 0.22
    }

    /// Camera-preset owned calibration data for the physical sensor boundary.
    /// This is never a display/preview gain.
    struct RadiometricCalibration: Codable, Equatable, Sendable {
        var baseExposureIndex = 100.0
        var referenceLambertianReflectance = 0.18
        var referenceIlluminanceLux = 100.0
        var referenceTStop = 4.0
        var referenceShutterSeconds = 1.0 / 48.0
        var effectiveSensorExposureScale = 1.0
    }

    struct Develop: Codable, Equatable, Sendable {
        var whiteBalance = [1.0, 1.0, 1.0]
        var middleGrayIlluminanceSeconds = 0.18
        var exposureEV = 0.0
        var demosaicAuthority = "Edge-directed"
    }

    struct Pose: Codable, Equatable, Sendable {
        var position = [0.0, 0.0, 1.0]
        var quaternion = [0.0, 0.0, 0.0, 1.0]
    }

    struct CameraLookAt: Codable, Equatable, Sendable {
        var enabled = true
        var target = [0.0, 0.0, 0.0]
    }

    var coverGlass: CoverGlassDefinition
    var environment = Environment()
    var sceneLens = SceneLens()
    var shutterMotion = ShutterMotion()
    var sensor = Sensor()
    var radiometricCalibration = RadiometricCalibration()
    var develop = Develop()
    var cameraPose = Pose()
    /// UI authoring aid only. The physical engine continues to receive one
    /// canonical quaternion, never a second orientation authority.
    var cameraLookAt: CameraLookAt?
    var screenPose = Pose(position: [0, 0, 0], quaternion: [0, 0, 0, 1])

    static func seeded(
        device: DeviceDefinition,
        coverGlass: CoverGlassDefinition
    ) throws -> Self {
        var value = Self(coverGlass: coverGlass)
        let defaults = try value.resolvedPipeline()
        value.cameraPose.position[2] = Double(try PhysicalStaticFraming(
            device: device,
            scene: defaults.parameters.scene_geometry_lens
        ).cameraDistanceMeters)
        value.sceneLens.focusDistanceMeters = value.cameraPose.position[2]
        value.cameraLookAt = CameraLookAt(target: value.screenPose.position)
        value.cameraPose.quaternion = PoseRotationProjection.quaternionLooking(
            from: value.cameraPose.position,
            to: value.screenPose.position
        )
        return value
    }

    func resolvedPipeline() throws -> PhysicalPipelineResolvedState {
        try validate()
        let version = UInt32(SCREEN_PHYSICAL_FRAME_ABI_VERSION)
        var environmentABI = ScreenEnvironmentParametersV2()
        environmentABI.abi_version = version
        environmentABI.character_strength = 1
        environmentABI.ambient_radiance_acescg = tuple3(environment.ambientRadianceACEScg)
        environmentABI.key_radiance_acescg = tuple3(environment.keyRadianceACEScg)
        environmentABI.key_direction_local = tuple3(environment.keyDirectionLocal)
        environmentABI.key_angular_radius_degrees = Float(environment.keyAngularRadiusDegrees)
        environmentABI.rotation_degrees = Float(environment.rotationDegrees)
        environmentABI.pattern = environment.pattern

        var scene = ScreenSceneGeometryLensParametersV2()
        scene.abi_version = version
        scene.focal_length_millimeters = Float(sceneLens.focalLengthMillimeters)
        scene.sensor_width_millimeters = Float(sceneLens.sensorWidthMillimeters)
        scene.sensor_height_millimeters = Float(sceneLens.sensorHeightMillimeters)
        scene.lens_shift = tuple2(sceneLens.lensShift)
        scene.focus_distance_meters = Float(sceneLens.focusDistanceMeters)
        scene.f_stop = Float(sceneLens.fStop)
        scene.near_clip_meters = Float(sceneLens.nearClipMeters)
        scene.far_clip_meters = Float(sceneLens.farClipMeters)
        scene.lens_radial_distortion = tuple3(sceneLens.radialDistortion)
        scene.lens_tangential_distortion = tuple2(sceneLens.tangentialDistortion)
        scene.lens_longitudinal_chromatic_meters = tuple3(sceneLens.longitudinalChromaticMeters)
        scene.lens_lateral_chromatic_scale = tuple3(sceneLens.lateralChromaticScale)
        scene.lens_vignetting_strength = Float(sceneLens.vignettingStrength)
        scene.lens_transmission_rgb = tuple3(sceneLens.transmissionRGB)
        scene.lens_center_softness_micrometers = Float(sceneLens.centerSoftnessMicrometers)
        scene.lens_edge_softness_micrometers = Float(sceneLens.edgeSoftnessMicrometers)

        var shutter = ScreenShutterMotionParametersV2()
        shutter.abi_version = version
        shutter.temporal_samples = shutterMotion.temporalSamples
        shutter.readout_kind = shutterMotion.readoutKind
        shutter.readout_duration_numerator = shutterMotion.readoutDurationNumerator
        shutter.readout_duration_denominator = shutterMotion.readoutDurationDenominator
        shutter.readout_direction = shutterMotion.readoutDirection
        shutter.neutral_density_stops = Float(shutterMotion.neutralDensityStops)
        shutter.noise_seed = shutterMotion.noiseSeed

        var sensorABI = ScreenSensorNoiseParametersV2()
        sensorABI.abi_version = version
        sensorABI.native_width = sensor.nativeWidth
        sensorABI.native_height = sensor.nativeHeight
        sensorABI.bayer_pattern = sensor.bayerPattern
        sensorABI.acescg_to_sensor = tuple9(sensor.acescgToSensor)
        sensorABI.saturation_illuminance_seconds = tuple3(sensor.saturationIlluminanceSeconds)
        sensorABI.full_well_electrons = Float(sensor.fullWellElectrons)
        sensorABI.dark_current_electrons_per_second = Float(sensor.darkCurrentElectronsPerSecond)
        sensorABI.read_noise_electrons_rms = Float(sensor.readNoiseElectronsRMS)
        sensorABI.analog_gain = Float(sensor.analogGain)
        sensorABI.adc_bits = sensor.adcBits
        sensorABI.bloom_character_strength = Float(sensor.bloomCharacterStrength)
        sensorABI.bloom_crosstalk_fraction = Float(sensor.bloomCrosstalkFraction)
        sensorABI.bloom_overflow_transfer_fraction = Float(sensor.bloomOverflowTransferFraction)

        var developABI = ScreenRawDevelopParametersV2()
        developABI.abi_version = version
        developABI.white_balance = tuple3(develop.whiteBalance)
        developABI.middle_gray_illuminance_seconds = Float(develop.middleGrayIlluminanceSeconds)
        developABI.develop_exposure_ev = Float(develop.exposureEV)

        var radiometricABI = ScreenCameraRadiometricCalibrationV2()
        radiometricABI.abi_version = version
        radiometricABI.base_exposure_index = Float(radiometricCalibration.baseExposureIndex)
        radiometricABI.reference_lambertian_reflectance = Float(radiometricCalibration.referenceLambertianReflectance)
        radiometricABI.reference_illuminance_lux = Float(radiometricCalibration.referenceIlluminanceLux)
        radiometricABI.reference_t_stop = Float(radiometricCalibration.referenceTStop)
        radiometricABI.reference_shutter_seconds = Float(radiometricCalibration.referenceShutterSeconds)
        radiometricABI.effective_sensor_exposure_scale = Float(radiometricCalibration.effectiveSensorExposureScale)

        var parameters = ScreenPhysicalPipelineParametersV2()
        parameters.abi_version = version
        parameters.cover = try coverGlass.bridgeParameters()
        parameters.environment = environmentABI
        parameters.scene_geometry_lens = scene
        parameters.shutter_motion = shutter
        parameters.sensor_noise = sensorABI
        parameters.raw_develop = developABI
        parameters.radiometric_calibration = radiometricABI
        return PhysicalPipelineResolvedState(parameters: parameters, coverGlassID: coverGlass.id)
    }

    func orchestration(for frame: PhysicalFrameSelection) throws -> PhysicalFrameOrchestration {
        try validate()
        return PhysicalFrameOrchestration(
            frame: frame,
            shutter: PhysicalShutterInterval(
                open: try offsetTime(
                    frame: frame,
                    numerator: shutterMotion.openOffsetNumerator,
                    denominator: shutterMotion.openOffsetDenominator
                ),
                close: try offsetTime(
                    frame: frame,
                    numerator: shutterMotion.closeOffsetNumerator,
                    denominator: shutterMotion.closeOffsetDenominator
                )
            ),
            cameraPose: try pose(cameraPose),
            screenPose: try pose(screenPose),
            isStaticInput: true
        )
    }

    func validate() throws {
        try coverGlass.validate()
        let vectors = [
            environment.ambientRadianceACEScg, environment.keyRadianceACEScg,
            environment.keyDirectionLocal, sceneLens.radialDistortion,
            sceneLens.longitudinalChromaticMeters, sceneLens.lateralChromaticScale,
            sceneLens.transmissionRGB, sensor.saturationIlluminanceSeconds,
            develop.whiteBalance, cameraPose.position, cameraPose.quaternion,
            screenPose.position, screenPose.quaternion,
        ]
        guard vectors.enumerated().allSatisfy({ index, values in
            let expected = [10, 12].contains(index) ? 4 : 3
            return values.count == expected && values.allSatisfy(\.isFinite)
        }), sceneLens.lensShift.count == 2,
            sceneLens.tangentialDistortion.count == 2,
            sensor.acescgToSensor.count == 9,
            shutterMotion.readoutDurationDenominator > 0,
            shutterMotion.openOffsetDenominator > 0,
            shutterMotion.closeOffsetDenominator > 0,
            sensor.nativeWidth > 0, sensor.nativeHeight > 0,
            sensor.adcBits > 0, sensor.adcBits < 32,
            sceneLens.focalLengthMillimeters > 0,
            sceneLens.sensorWidthMillimeters > 0,
            sceneLens.sensorHeightMillimeters > 0,
            sceneLens.focusDistanceMeters > 0,
            sceneLens.fStop > 0,
            sceneLens.nearClipMeters > 0,
            sceneLens.farClipMeters > sceneLens.nearClipMeters,
            sensor.fullWellElectrons > 0,
            sensor.analogGain > 0,
            develop.middleGrayIlluminanceSeconds > 0
        else {
            throw DeviceDomainError.invalidPhysicalProfile(
                "Los overrides físicos no cumplen el dominio seguro del snapshot ABI v3."
            )
        }
    }

    private func pose(_ value: Pose) throws -> PhysicalPoseSnapshot {
        let q = value.quaternion
        let norm = sqrt(q.reduce(0) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 0 else {
            throw DeviceDomainError.invalidPhysicalProfile("Quaternion de pose no válido.")
        }
        return PhysicalPoseSnapshot(
            position: .init(
                x: Float(value.position[0]),
                y: Float(value.position[1]),
                z: Float(value.position[2])
            ),
            rotation: .init(
                x: Float(q[0] / norm), y: Float(q[1] / norm),
                z: Float(q[2] / norm), w: Float(q[3] / norm)
            )
        )
    }

    private func offsetTime(
        frame: PhysicalFrameSelection,
        numerator: Int64,
        denominator: UInt32
    ) throws -> PhysicalRationalTime {
        // Add the two rationals through their least common denominator. Capture
        // presets commonly author shutter/readout values against a 1 GHz clock;
        // multiplying that denominator directly by 24/25/30 fps overflowed the
        // UInt32 ABI denominator and left the previous preview frame visible.
        let reduction = gcd(numerator.magnitude, UInt64(denominator))
        let reducedNumerator = numerator / Int64(reduction)
        let reducedDenominator = denominator / UInt32(reduction)
        let common = UInt32(gcd(
            UInt64(frame.timeDenominator),
            UInt64(reducedDenominator)
        ))
        let frameMultiplier = reducedDenominator / common
        let offsetMultiplier = frame.timeDenominator / common
        let (framePart, a) = frame.timeNumerator.multipliedReportingOverflow(
            by: Int64(frameMultiplier)
        )
        let (offsetPart, b) = reducedNumerator.multipliedReportingOverflow(
            by: Int64(offsetMultiplier)
        )
        let (sum, c) = framePart.addingReportingOverflow(offsetPart)
        let resolvedDenominator = UInt64(frame.timeDenominator) * UInt64(frameMultiplier)
        guard !a, !b, !c, resolvedDenominator <= UInt64(UInt32.max) else {
            throw PhysicalContractError.invalidFrameTime
        }
        return try PhysicalRationalTime(
            numerator: sum,
            denominator: UInt32(resolvedDenominator)
        )
    }

    private func gcd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        var a = lhs
        var b = rhs
        while b != 0 {
            (a, b) = (b, a % b)
        }
        return a
    }
}

extension PhysicalPipelineAuthoringState {
    mutating func restore(
        section: CapturePhysicalSection,
        from base: PhysicalPipelineAuthoringState
    ) {
        switch section {
        case .geometry:
            cameraPose = base.cameraPose
            cameraLookAt = base.cameraLookAt
            sceneLens.nearClipMeters = base.sceneLens.nearClipMeters
            sceneLens.farClipMeters = base.sceneLens.farClipMeters
        case .lens:
            sceneLens = base.sceneLens
        case .exposureShutter:
            shutterMotion = base.shutterMotion
        case .sensorCFA:
            sensor.nativeWidth = base.sensor.nativeWidth
            sensor.nativeHeight = base.sensor.nativeHeight
            sensor.bayerPattern = base.sensor.bayerPattern
            sensor.acescgToSensor = base.sensor.acescgToSensor
            sensor.saturationIlluminanceSeconds = base.sensor.saturationIlluminanceSeconds
            sensor.fullWellElectrons = base.sensor.fullWellElectrons
            sensor.adcBits = base.sensor.adcBits
        case .sensorBloom:
            sensor.bloomCharacterStrength = base.sensor.bloomCharacterStrength
            sensor.bloomCrosstalkFraction = base.sensor.bloomCrosstalkFraction
            sensor.bloomOverflowTransferFraction = base.sensor.bloomOverflowTransferFraction
        case .noise:
            sensor.darkCurrentElectronsPerSecond = base.sensor.darkCurrentElectronsPerSecond
            sensor.readNoiseElectronsRMS = base.sensor.readNoiseElectronsRMS
            sensor.analogGain = base.sensor.analogGain
            shutterMotion.noiseSeed = base.shutterMotion.noiseSeed
        case .developDemosaic:
            develop = base.develop
        }
    }
}

extension DeviceDefinition {
    mutating func restore(section: ScreenPhysicalSection, from base: DeviceDefinition) {
        switch section {
        case .emission:
            panelTechnology = base.panelTechnology
            emissionModel = base.emissionModel
            eotfGamma = base.eotfGamma
            blackLevelNits = base.blackLevelNits
            whiteLevelNits = base.whiteLevelNits
            whiteBasis = base.whiteBasis
            red = base.red
            green = base.green
            blue = base.blue
            white = base.white
            angularEmissionPower = base.angularEmissionPower
        case .subpixelGeometry:
            nativeWidth = base.nativeWidth
            nativeHeight = base.nativeHeight
            activeWidthMeters = base.activeWidthMeters
            activeHeightMeters = base.activeHeightMeters
            stripeLayout = base.stripeLayout
            blackMatrixFraction = base.blackMatrixFraction
        case .panelLightSpread:
            panelLightSpread = base.panelLightSpread
        case .temporal:
            residualFlickerPeriod = base.residualFlickerPeriod
            residualFlickerAmplitude = base.residualFlickerAmplitude
            residualFlickerPhase = base.residualFlickerPhase
            bandingPeriod = base.bandingPeriod
            bandingOnDuration = base.bandingOnDuration
            bandingPhase = base.bandingPhase
            bandingAmount = base.bandingAmount
        case .coverGlass, .environment, .coverGlow:
            break
        }
    }
}

private func tuple2(_ values: [Double]) -> (Float, Float) {
    (Float(values[0]), Float(values[1]))
}

private func tuple3(_ values: [Double]) -> (Float, Float, Float) {
    (Float(values[0]), Float(values[1]), Float(values[2]))
}

private func tuple9(_ values: [Double]) -> (
    Float, Float, Float, Float, Float, Float, Float, Float, Float
) {
    (
        Float(values[0]), Float(values[1]), Float(values[2]),
        Float(values[3]), Float(values[4]), Float(values[5]),
        Float(values[6]), Float(values[7]), Float(values[8])
    )
}
