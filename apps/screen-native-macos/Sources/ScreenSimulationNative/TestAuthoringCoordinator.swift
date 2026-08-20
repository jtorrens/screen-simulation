import Foundation
import ScreenPhysicalBridge
import ScreenSimulationPresentation

enum TestPreviewResultKind: UInt32, Sendable {
    case sourceACEScg = 0
    case sourceAdjustment = 1
    case feederSignal = 2
    case deviceInterpretation = 3
    case panelStructure = 4
    case panelUniformity = 5
    case panelLightSpread = 6
    case relativeGeometry = 7
    case coverEnvironment = 8
    case coverGlow = 9
    case lensProjection = 10
    case shutterExposure = 11
    case computationalCapture = 12
    case sensorCollection = 13
    case sensorBloom = 14
    case sensorReadoutRaw = 15
    case developDemosaic = 16
    case cameraRenderingIntent = 17
    case deliveryRaster = 18
    case recordingOutput = 19
    case recordingCodec = 20
    case deviceVfxTransparency = 21
    case panelTemporal = 22
}

struct TestAuthoringResolvedSelection: Codable, Equatable, Sendable {
    let inputTransformID: String
    let outputSignalID: String
    let deviceID: String
    var colorModeID: String
    var deviceEOTFGamma: Double
    var whiteLuminanceNits: Double
    let placementID: String
    var previewQualityID: String
    var frameRate: ExactFrameRate
    let sourceExposureEV: Double
    let sourceContrast: Double
    let sourceSaturation: Double
    let sourceTemperatureKelvin: Double
    let sourceTint: Double
    let subpixelGeometryAmount: Double
    let moireIntensity: Double
    let moireSaturation: Double
    let moireFilterStrength: Double
    var panelUniformityAmount: Double
    var panelLightSpreadAmount: Double
    let capturePresetID: String
    let captureRasterModeID: String
    let lensEvaluationModelID: String
    var geometryModeID: String
    let cameraDistanceMeters: Double
    let cameraOrbitXDegrees: Double
    let cameraOrbitYDegrees: Double
    var cameraPositionXMeters: Double
    var cameraPositionYMeters: Double
    var cameraPositionZMeters: Double
    var cameraRotationXDegrees: Double
    var cameraRotationYDegrees: Double
    var cameraRotationZDegrees: Double
    var screenPositionXMeters: Double
    var screenPositionYMeters: Double
    var screenPositionZMeters: Double
    var screenRotationXDegrees: Double
    var screenYawDegrees: Double
    var screenRotationZDegrees: Double
    var coverGlassPresetID: String
    var coverGlassAmount: Double
    var coverAgMicrotextureAmount: Double
    var coverThicknessMillimeters: Double
    var coverRefractiveIndex: Double
    var coverAREfficiency: Double
    var coverAbsorptionRGB: [Double]
    var coverRoughness: Double
    var coverHaze: Double
    var coverAgRMSSlope: Double
    var coverAgCorrelationMicrometers: Double
    var coverAgAnisotropy: Double
    let environmentSourceID: String
    let environmentAmount: Double
    var environmentRotationXDegrees: Double
    var environmentRotationYDegrees: Double
    var environmentAnchorLongitudeDegrees: Double
    var environmentAnchorLatitudeDegrees: Double
    var environmentTangentTransform: [Double]
    let environmentExposureEV: Double
    let environmentContrast: Double
    let environmentSaturation: Double
    let environmentTemperatureKelvin: Double
    let environmentTint: Double
    var environmentProjectionID: String
    var environmentSphereCenterXMeters: Double
    var environmentSphereCenterYMeters: Double
    var environmentSphereCenterZMeters: Double
    var environmentSphereRadiusMeters: Double
    var coverGlowAmount: Double
    var coverGlowIntensity: Double
    var coverGlowRadiusMillimeters: Double
    var coverGlowThresholdRelativeWhite: Double
    var coverGlowExteriorIntensity: Double
    let lensPresetID: String
    var focalLengthMillimeters: Double
    let lensAmount: Double
    let autofocusEnabled: Bool
    let autofocusTargetU: Double
    let autofocusTargetV: Double
    let focusDistanceMeters: Double
    let fStop: Double
    let exposureTimeSeconds: Double
    let shutterMotionAmount: Double
    let computationalCharacterStrength: Double
    let computationalExposureCount: Double
    let computationalBracketSpacingStops: Double
    let sensorBloomAmount: Double
    let sensorBloomCrosstalkFraction: Double
    let sensorBloomOverflowTransferFraction: Double
    let sensorNoiseAmount: Double
    let cameraLookExposureEV: Double
    let cameraLookContrast: Double
    let cameraLookSaturation: Double
    let cameraLookTemperatureKelvin: Double
    let cameraLookTint: Double
    let deviceVfxAlphaModeID: String
    let deliveryPresetID: String
    let deliveryWidth: UInt32
    let deliveryHeight: UInt32
    let deliveryPlacementID: String
    let deliveryBackgroundID: String
    let recordingOutputTransformID: String
    let recordingProfileID: String
    let recordingCharacter: Double
}

struct TestAuthoringSnapshot: Sendable {
    let presentation: TestPagePresentation
    let previewResultByPhaseID: [String: TestPreviewResultKind]
    let physicalIntermediateByPhaseID: [String: PhysicalIntermediate]
    let resolvedSelection: TestAuthoringResolvedSelection
}

private struct TestInspectorPlacement {
    let groupID: String
    let groupLabel: String
    let groupOrder: Int
    let sectionID: String
    let sectionLabel: String
    let sectionOrder: Int
    let control: TestControlDescriptor
}

enum TestAuthoringCoordinatorError: Error, LocalizedError {
    case bridge(String)
    case malformedDescriptor(String)
    case unsupportedIntent

    var errorDescription: String? {
        switch self {
        case let .bridge(message): message
        case let .malformedDescriptor(message): message
        case .unsupportedIntent: "Application/Rust no admite esta intención de Test."
        }
    }
}

final class RustTestAuthoringProfileContext: @unchecked Sendable {
    let handle: ScreenTestAuthoringProfileContextRef

    init(library: GlobalLibraryDocument) throws {
        try library.validate()
        var allocated: [UnsafeMutablePointer<CChar>] = []
        func owned(_ value: String) throws -> UnsafeMutablePointer<CChar> {
            guard let pointer = strdup(value) else {
                throw TestAuthoringCoordinatorError.bridge(
                    "No se pudo materializar el contexto de perfiles."
                )
            }
            allocated.append(pointer)
            return pointer
        }
        func view(_ pointer: UnsafeMutablePointer<CChar>) -> ScreenUTF8View {
            ScreenUTF8View(
                bytes: UnsafePointer<UInt8>(OpaquePointer(pointer)),
                count: Int(strlen(pointer))
            )
        }
        defer { allocated.forEach { free(UnsafeMutableRawPointer($0)) } }

        struct DeviceStorage {
            let id: UnsafeMutablePointer<CChar>
            let label: UnsafeMutablePointer<CChar>
            let defaultColorMode: UnsafeMutablePointer<CChar>
            let defaultCover: UnsafeMutablePointer<CChar>
            let colorOffset: Int
            let colorCount: Int
            let parameters: ScreenDeviceParametersV3
            let minimumWhite: Float
            let maximumWhite: Float
            let whiteStep: Float
        }
        var colorViews: [ScreenUTF8View] = []
        var deviceStorage: [DeviceStorage] = []
        for item in library.devices {
            let device = item.value
            let offset = colorViews.count
            for colorModeID in device.colorModeIDs {
                colorViews.append(view(try owned(colorModeID)))
            }
            deviceStorage.append(DeviceStorage(
                id: try owned(device.id), label: try owned(device.name),
                defaultColorMode: try owned(device.colorModeID),
                defaultCover: try owned(device.defaultCoverGlassPresetID),
                colorOffset: offset, colorCount: device.colorModeIDs.count,
                parameters: try device.bridgeParameters(),
                minimumWhite: Float(device.minimumWhiteLuminance),
                maximumWhite: Float(device.maximumWhiteLuminance),
                whiteStep: Float(device.whiteLuminanceStep)
            ))
        }
        let coverStorage = try library.coverGlasses.map { item in
            (
                id: try owned(item.value.id),
                label: try owned(item.value.name),
                parameters: try item.value.bridgeParameters()
            )
        }
        struct CaptureStorage {
            let id: UnsafeMutablePointer<CChar>
            let label: UnsafeMutablePointer<CChar>
            let parameters: ScreenCapturePresetParametersV4
            let defaultRecording: UnsafeMutablePointer<CChar>
            let recordingOffset: Int
            let recordingCount: Int
            let defaultLens: UnsafeMutablePointer<CChar>
            let lensOffset: Int
            let lensCount: Int
        }
        var recordingViews: [ScreenUTF8View] = []
        var lensAssociationViews: [ScreenUTF8View] = []
        var captureStorage: [CaptureStorage] = []
        for item in library.cameras {
            let camera = item.value
            let recordingOffset = recordingViews.count
            for id in camera.recommendedRecordingProfileIDs {
                recordingViews.append(view(try owned(id)))
            }
            let lensOffset = lensAssociationViews.count
            for id in camera.compatibleLensIDs {
                lensAssociationViews.append(view(try owned(id)))
            }
            let modes = try camera.rasterModes.map { mode -> ScreenCaptureRasterModeV1 in
                ScreenCaptureRasterModeV1(
                    id: view(try owned(mode.id)),
                    label: view(try owned(mode.name)),
                    width: mode.width,
                    height: mode.height
                )
            }
            guard modes.count == 3 else {
                throw TestAuthoringCoordinatorError.bridge(
                    "Cada cámara debe declarar exactamente tres rasters."
                )
            }
            var parameters = ScreenCapturePresetParametersV4()
            parameters.abi_version = UInt32(SCREEN_AUTHORING_CATALOG_ABI_VERSION)
            parameters.sensor.abi_version = UInt32(SCREEN_PHYSICAL_FRAME_ABI_VERSION)
            parameters.sensor.native_width = camera.sensor.nativeWidth
            parameters.sensor.native_height = camera.sensor.nativeHeight
            parameters.sensor.bayer_pattern = camera.sensor.bayerPattern
            parameters.sensor.acescg_to_sensor = (
                Float(camera.sensor.acescgToSensor[0]), Float(camera.sensor.acescgToSensor[1]),
                Float(camera.sensor.acescgToSensor[2]), Float(camera.sensor.acescgToSensor[3]),
                Float(camera.sensor.acescgToSensor[4]), Float(camera.sensor.acescgToSensor[5]),
                Float(camera.sensor.acescgToSensor[6]), Float(camera.sensor.acescgToSensor[7]),
                Float(camera.sensor.acescgToSensor[8])
            )
            parameters.sensor.saturation_illuminance_seconds = (
                Float(camera.sensor.saturationIlluminanceSeconds[0]),
                Float(camera.sensor.saturationIlluminanceSeconds[1]),
                Float(camera.sensor.saturationIlluminanceSeconds[2])
            )
            parameters.sensor.full_well_electrons = Float(camera.sensor.fullWellElectrons)
            parameters.sensor.dark_current_electrons_per_second = Float(camera.sensor.darkCurrentElectronsPerSecond)
            parameters.sensor.read_noise_electrons_rms = Float(camera.sensor.readNoiseElectronsRMS)
            parameters.sensor.analog_gain = Float(camera.sensor.analogGain)
            parameters.sensor.adc_bits = camera.sensor.adcBits
            parameters.sensor.bloom_character_strength = Float(camera.sensor.bloomCharacterStrength)
            parameters.sensor.bloom_crosstalk_fraction = Float(camera.sensor.bloomCrosstalkFraction)
            parameters.sensor.bloom_overflow_transfer_fraction = Float(camera.sensor.bloomOverflowTransferFraction)
            parameters.computational_capture.abi_version = UInt32(SCREEN_PHYSICAL_FRAME_ABI_VERSION)
            parameters.computational_capture.exposure_count = camera.computationalCapture.exposureCount
            parameters.computational_capture.bracket_spacing_stops = Float(camera.computationalCapture.bracketSpacingStops)
            parameters.camera_rendering_intent.abi_version = UInt32(SCREEN_PHYSICAL_FRAME_ABI_VERSION)
            parameters.camera_rendering_intent.exposure_ev = Float(camera.renderingIntent.exposureEV)
            parameters.camera_rendering_intent.contrast = Float(camera.renderingIntent.contrast)
            parameters.camera_rendering_intent.saturation = Float(camera.renderingIntent.saturation)
            parameters.camera_rendering_intent.temperature_kelvin = Float(camera.renderingIntent.temperatureKelvin)
            parameters.camera_rendering_intent.tint = Float(camera.renderingIntent.tint)
            parameters.gate_width_millimeters = Float(camera.gateWidthMillimeters)
            parameters.gate_height_millimeters = Float(camera.gateHeightMillimeters)
            parameters.default_f_stop = Float(camera.defaultFStop)
            parameters.reference_exposure_index = Float(camera.referenceExposureIndex)
            parameters.middle_gray_illuminance_seconds = Float(camera.middleGrayIlluminanceSeconds)
            parameters.default_shutter_angle_degrees = Float(camera.defaultShutterAngleDegrees)
            parameters.default_temporal_samples = camera.defaultTemporalSamples
            parameters.lens_association_policy = camera.lensAssociationPolicy
            parameters.radiometric_calibration.abi_version = UInt32(SCREEN_PHYSICAL_FRAME_ABI_VERSION)
            parameters.radiometric_calibration.base_exposure_index = Float(camera.radiometricCalibration.baseExposureIndex)
            parameters.radiometric_calibration.reference_lambertian_reflectance = Float(camera.radiometricCalibration.referenceLambertianReflectance)
            parameters.radiometric_calibration.reference_illuminance_lux = Float(camera.radiometricCalibration.referenceIlluminanceLux)
            parameters.radiometric_calibration.reference_t_stop = Float(camera.radiometricCalibration.referenceTStop)
            parameters.radiometric_calibration.reference_shutter_seconds = Float(camera.radiometricCalibration.referenceShutterSeconds)
            parameters.radiometric_calibration.effective_sensor_exposure_scale = Float(camera.radiometricCalibration.effectiveSensorExposureScale)
            parameters.raster_modes = (modes[0], modes[1], modes[2])
            parameters.default_raster_mode_id = view(try owned(camera.defaultRasterModeID))
            parameters.default_lens_evaluation_model = camera.defaultLensEvaluationModelID == "thin-lens" ? 0 : 1
            parameters.native_vfx_encoding_id = view(try owned(camera.nativeVFXEncodingID ?? ""))
            captureStorage.append(CaptureStorage(
                id: try owned(camera.id), label: try owned(camera.name), parameters: parameters,
                defaultRecording: try owned(camera.defaultRecordingProfileID),
                recordingOffset: recordingOffset,
                recordingCount: camera.recommendedRecordingProfileIDs.count,
                defaultLens: try owned(camera.defaultLensID),
                lensOffset: lensOffset,
                lensCount: camera.compatibleLensIDs.count
            ))
        }
        let lensStorage = try library.lenses.map { item -> (
            id: UnsafeMutablePointer<CChar>, label: UnsafeMutablePointer<CChar>,
            parameters: ScreenLensPresetParametersV1
        ) in
            let lens = item.value
            var parameters = ScreenLensPresetParametersV1()
            parameters.abi_version = UInt32(SCREEN_AUTHORING_CATALOG_ABI_VERSION)
            parameters.nominal_focal_length_millimeters = Float(lens.nominalFocalLengthMillimeters)
            parameters.radial_distortion = (Float(lens.radialDistortion[0]), Float(lens.radialDistortion[1]), Float(lens.radialDistortion[2]))
            parameters.tangential_distortion = (Float(lens.tangentialDistortion[0]), Float(lens.tangentialDistortion[1]))
            parameters.longitudinal_chromatic_meters = (Float(lens.longitudinalChromaticMeters[0]), Float(lens.longitudinalChromaticMeters[1]), Float(lens.longitudinalChromaticMeters[2]))
            parameters.lateral_chromatic_scale = (Float(lens.lateralChromaticScale[0]), Float(lens.lateralChromaticScale[1]), Float(lens.lateralChromaticScale[2]))
            parameters.vignetting_strength = Float(lens.vignettingStrength)
            parameters.transmission_rgb = (Float(lens.transmissionRGB[0]), Float(lens.transmissionRGB[1]), Float(lens.transmissionRGB[2]))
            parameters.center_softness_micrometers = Float(lens.centerSoftnessMicrometers)
            parameters.edge_softness_micrometers = Float(lens.edgeSoftnessMicrometers)
            parameters.veiling_glare_fraction = Float(lens.veilingGlareFraction)
            return (try owned(lens.id), try owned(lens.name), parameters)
        }
        let environmentStorage = try library.environments.map { item -> (
            id: UnsafeMutablePointer<CChar>, label: UnsafeMutablePointer<CChar>,
            parameters: ScreenEnvironmentParametersV2
        ) in
            let profile = item.value
            let environment = profile.environment
            var parameters = ScreenEnvironmentParametersV2()
            parameters.abi_version = UInt32(SCREEN_PHYSICAL_FRAME_ABI_VERSION)
            parameters.source_kind = environment.sourceKind
            parameters.character_strength = 1
            parameters.source_unit_radiance_candelas_per_square_meter = Float(environment.sourceUnitRadianceCandelasPerSquareMeter)
            parameters.exposure_stops = Float(environment.exposureStops)
            parameters.ambient_radiance_acescg = (Float(environment.ambientRadianceACEScg[0]), Float(environment.ambientRadianceACEScg[1]), Float(environment.ambientRadianceACEScg[2]))
            parameters.key_radiance_acescg = (Float(environment.keyRadianceACEScg[0]), Float(environment.keyRadianceACEScg[1]), Float(environment.keyRadianceACEScg[2]))
            parameters.key_direction_local = (Float(environment.keyDirectionLocal[0]), Float(environment.keyDirectionLocal[1]), Float(environment.keyDirectionLocal[2]))
            parameters.key_angular_radius_degrees = Float(environment.keyAngularRadiusDegrees)
            parameters.rotation_x_degrees = Float(environment.rotationXDegrees)
            parameters.rotation_y_degrees = Float(environment.rotationYDegrees)
            parameters.placement_anchor_direction_world = (0, 0, 1)
            parameters.placement_source_direction = (0, 0, 1)
            parameters.placement_tangent_transform = (1, 0, 0, 0)
            parameters.pattern = environment.pattern
            return (try owned(profile.id), try owned(profile.name), parameters)
        }
        var error: UnsafePointer<CChar>?
        let created = colorViews.withUnsafeBufferPointer { colors in
            let rawDevices = deviceStorage.map { stored in
                ScreenTestDeviceProfileV1(
                    abi_version: UInt32(SCREEN_TEST_AUTHORING_ABI_VERSION),
                    id: view(stored.id), label: view(stored.label),
                    parameters: stored.parameters,
                    color_mode_ids: colors.baseAddress?.advanced(by: stored.colorOffset),
                    color_mode_count: stored.colorCount,
                    default_color_mode_id: view(stored.defaultColorMode),
                    minimum_white_nits: stored.minimumWhite,
                    maximum_white_nits: stored.maximumWhite,
                    white_step_nits: stored.whiteStep,
                    default_cover_glass_profile_id: view(stored.defaultCover)
                )
            }
            let rawCovers = coverStorage.map { stored in
                ScreenTestCoverProfileV1(
                    abi_version: UInt32(SCREEN_TEST_AUTHORING_ABI_VERSION),
                    id: view(stored.id), label: view(stored.label),
                    parameters: stored.parameters
                )
            }
            let rawLenses = lensStorage.map { stored in
                ScreenTestLensProfileV1(
                    abi_version: UInt32(SCREEN_TEST_AUTHORING_ABI_VERSION),
                    id: view(stored.id), label: view(stored.label),
                    parameters: stored.parameters
                )
            }
            let rawEnvironments = environmentStorage.map { stored in
                ScreenTestEnvironmentProfileV1(
                    abi_version: UInt32(SCREEN_TEST_AUTHORING_ABI_VERSION),
                    id: view(stored.id), label: view(stored.label),
                    parameters: stored.parameters
                )
            }
            return recordingViews.withUnsafeBufferPointer { recordings in
                lensAssociationViews.withUnsafeBufferPointer { lensAssociations in
                    let rawCaptures = captureStorage.map { stored in
                        ScreenTestCaptureProfileV1(
                            abi_version: UInt32(SCREEN_TEST_AUTHORING_ABI_VERSION),
                            id: view(stored.id), label: view(stored.label),
                            parameters: stored.parameters,
                            default_recording_profile_id: view(stored.defaultRecording),
                            recommended_recording_profile_ids: recordings.baseAddress?.advanced(by: stored.recordingOffset),
                            recommended_recording_profile_count: stored.recordingCount,
                            default_lens_profile_id: view(stored.defaultLens),
                            compatible_lens_profile_ids: lensAssociations.baseAddress?.advanced(by: stored.lensOffset),
                            compatible_lens_profile_count: stored.lensCount
                        )
                    }
                    return rawDevices.withUnsafeBufferPointer { devices in
                        rawCovers.withUnsafeBufferPointer { covers in
                            rawCaptures.withUnsafeBufferPointer { captures in
                                rawLenses.withUnsafeBufferPointer { lenses in
                                    rawEnvironments.withUnsafeBufferPointer { environments in
                                        screen_test_authoring_profile_context_create(
                                            devices.baseAddress, devices.count,
                                            covers.baseAddress, covers.count,
                                            captures.baseAddress, captures.count,
                                            lenses.baseAddress, lenses.count,
                                            environments.baseAddress, environments.count,
                                            &error
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        guard let created else {
            throw TestAuthoringCoordinatorError.bridge(
                error.map(String.init(cString:))
                    ?? "Application rechazó la Biblioteca Global de perfiles."
            )
        }
        handle = created
    }

    deinit {
        screen_test_authoring_profile_context_release(handle)
    }
}

enum RustTestAuthoringCoordinator {
    private static func bundledSeedProfileContext() throws -> RustTestAuthoringProfileContext {
        try RustTestAuthoringProfileContext(library: GlobalLibraryDocument())
    }

    static func defaultSelection(
        inputTransformID: String,
        deviceID: String,
        frameRate: ExactFrameRate
    ) throws -> TestAuthoringResolvedSelection {
        try defaultSelection(
            profileContext: bundledSeedProfileContext(),
            inputTransformID: inputTransformID,
            deviceID: deviceID,
            frameRate: frameRate
        )
    }

    static func defaultSelection(
        profileContext: RustTestAuthoringProfileContext,
        inputTransformID: String,
        deviceID: String,
        frameRate: ExactFrameRate
    ) throws -> TestAuthoringResolvedSelection {
        try withUTF8View(inputTransformID) { inputView in
            try withUTF8View(deviceID) { deviceView in
                var output = ScreenTestAuthoringSelectionV23()
                var error: UnsafePointer<CChar>?
                guard screen_test_authoring_default_selection_with_profiles(
                    profileContext.handle, inputView, deviceView,
                    frameRate.numerator, frameRate.denominator,
                    &output, &error
                ) else {
                    throw TestAuthoringCoordinatorError.bridge(
                        error.map(String.init(cString:))
                            ?? "Rust no pudo crear la selección inicial de Test."
                    )
                }
                return try resolved(output)
            }
        }
    }

    static func snapshot(
        profileContext: RustTestAuthoringProfileContext,
        selection: TestAuthoringResolvedSelection,
        selectedPreviewPhaseID: String?
    ) throws -> TestAuthoringSnapshot {
        try withRawSelection(selection) { rawSelection in
            var error: UnsafePointer<CChar>?
            guard let descriptor = screen_test_page_descriptor_create_with_profiles(
                profileContext.handle, rawSelection, &error
            ) else {
                throw TestAuthoringCoordinatorError.bridge(
                    error.map(String.init(cString:)) ?? "Rust rechazó el descriptor de Test."
                )
            }
            defer { screen_test_page_descriptor_release(descriptor) }

            let defaultPhaseID = string(
                screen_test_page_default_preview_phase_id(descriptor)
            )
            let phaseCount = screen_test_page_phase_count(descriptor)
            var phases: [TestPhasePresentation] = []
            var inspectorPlacements: [TestInspectorPlacement] = []
            var previewResults: [String: TestPreviewResultKind] = [:]
            var physicalIntermediates: [String: PhysicalIntermediate] = [:]
            phases.reserveCapacity(phaseCount)
            for phaseIndex in 0..<phaseCount {
                var rawPhase = ScreenTestPhaseDescriptorV5()
                guard screen_test_page_phase_descriptor(
                    descriptor, phaseIndex, &rawPhase
                ) else {
                    throw TestAuthoringCoordinatorError.malformedDescriptor(
                        "Rust no publicó la fase \(phaseIndex)."
                    )
                }
                let phaseID = string(rawPhase.id)
                guard let previewResult = TestPreviewResultKind(
                    rawValue: rawPhase.preview_result
                ) else {
                    throw TestAuthoringCoordinatorError.malformedDescriptor(
                        "La fase \(phaseID) tiene un resultado de Preview desconocido."
                    )
                }
                let controlCount = screen_test_page_control_count(descriptor, phaseIndex)
                var controls: [TestControlDescriptor] = []
                controls.reserveCapacity(controlCount)
                for controlIndex in 0..<controlCount {
                    let control = try controlDescriptor(
                        descriptor: descriptor,
                        phaseIndex: phaseIndex,
                        controlIndex: controlIndex
                    )
                    controls.append(control)
                    var rawControl = ScreenTestControlDescriptorV5()
                    guard screen_test_page_control_descriptor(
                        descriptor, phaseIndex, controlIndex, &rawControl
                    ) else {
                        throw TestAuthoringCoordinatorError.malformedDescriptor(
                            "Rust no publicó la ubicación del control \(phaseID):\(controlIndex)."
                        )
                    }
                    let groupID = string(rawControl.inspector_group_id)
                    let sectionID = string(rawControl.inspector_section_id)
                    guard !groupID.isEmpty, !sectionID.isEmpty else {
                        throw TestAuthoringCoordinatorError.malformedDescriptor(
                            "Rust no asignó el control \(control.id) al inspector."
                        )
                    }
                    inspectorPlacements.append(.init(
                        groupID: groupID,
                        groupLabel: string(rawControl.inspector_group_label),
                        groupOrder: Int(rawControl.inspector_group_order),
                        sectionID: sectionID,
                        sectionLabel: string(rawControl.inspector_section_label),
                        sectionOrder: Int(rawControl.inspector_section_order),
                        control: control
                    ))
                }
                let sections = controls.isEmpty ? [] : [
                    TestControlSection(
                        id: "\(phaseID).parameters",
                        label: "Parámetros",
                        controls: controls
                    ),
                ]
                phases.append(TestPhasePresentation(
                    id: phaseID,
                    label: string(rawPhase.label),
                    effectSummary: string(rawPhase.effect_summary),
                    headerControlID: optionalString(rawPhase.header_control_id),
                    inputArtifactID: string(rawPhase.input_artifact),
                    outputArtifactID: string(rawPhase.output_artifact),
                    calculationDomain: string(rawPhase.calculation_domain),
                    previewRoute: string(rawPhase.preview_route),
                    sections: sections
                ))
                previewResults[phaseID] = previewResult
                if rawPhase.has_physical_intermediate {
                    guard let intermediate = PhysicalIntermediate(
                        rawValue: rawPhase.physical_intermediate
                    ) else {
                        throw TestAuthoringCoordinatorError.malformedDescriptor(
                            "La fase \(phaseID) solicita un checkpoint físico desconocido."
                        )
                    }
                    physicalIntermediates[phaseID] = intermediate
                }
            }
            let selectedPhaseID = selectedPreviewPhaseID ?? defaultPhaseID
            guard phases.contains(where: { $0.id == selectedPhaseID }) else {
                throw TestAuthoringCoordinatorError.malformedDescriptor(
                    "La fase de Preview seleccionada no existe en el descriptor actual."
                )
            }
            let previewControls = try (0..<screen_test_page_preview_control_count(descriptor)).map {
                try previewControlDescriptor(descriptor: descriptor, controlIndex: $0)
            }
            let quickControlIDs = (0..<screen_test_page_quick_control_count(descriptor)).map {
                string(screen_test_page_quick_control_id(descriptor, $0))
            }
            let visiblePreviewChoiceIDs =
                (0..<screen_test_page_visible_preview_choice_count(descriptor)).map {
                    string(screen_test_page_visible_preview_choice_id(descriptor, $0))
                }
            let featuredPhaseID = string(screen_test_page_featured_phase_id(descriptor))
            let inspectorGroups = try inspectorGroups(from: inspectorPlacements)
            return TestAuthoringSnapshot(
                presentation: try TestPagePresentation(
                    phases: phases,
                    inspectorGroups: inspectorGroups,
                    selectedPhaseID: selectedPhaseID,
                    previewControls: previewControls,
                    visiblePreviewChoiceIDs: visiblePreviewChoiceIDs,
                    quickControlIDs: quickControlIDs,
                    featuredPhaseID: featuredPhaseID
                ),
                previewResultByPhaseID: previewResults,
                physicalIntermediateByPhaseID: physicalIntermediates,
                resolvedSelection: selection
            )
        }
    }

    private static func inspectorGroups(
        from placements: [TestInspectorPlacement]
    ) throws -> [TestInspectorGroupPresentation] {
        let grouped = Dictionary(grouping: placements, by: \.groupID)
        return try grouped.map { groupID, groupPlacements in
            guard let first = groupPlacements.first,
                  groupPlacements.allSatisfy({
                      $0.groupLabel == first.groupLabel && $0.groupOrder == first.groupOrder
                  })
            else {
                throw TestAuthoringCoordinatorError.malformedDescriptor(
                    "Rust publicó un grupo de inspector contradictorio: \(groupID)."
                )
            }
            let sections = try Dictionary(grouping: groupPlacements, by: \.sectionID).map {
                sectionID, sectionPlacements in
                guard let sectionFirst = sectionPlacements.first,
                      sectionPlacements.allSatisfy({
                          $0.sectionLabel == sectionFirst.sectionLabel
                              && $0.sectionOrder == sectionFirst.sectionOrder
                      })
                else {
                    throw TestAuthoringCoordinatorError.malformedDescriptor(
                        "Rust publicó una sección de inspector contradictoria: \(sectionID)."
                    )
                }
                return TestInspectorSectionPresentation(
                    id: sectionID,
                    label: sectionFirst.sectionLabel,
                    order: sectionFirst.sectionOrder,
                    controls: sectionPlacements.map(\.control)
                )
            }.sorted { $0.order < $1.order }
            return TestInspectorGroupPresentation(
                id: groupID,
                label: first.groupLabel,
                order: first.groupOrder,
                sections: sections
            )
        }.sorted { $0.order < $1.order }
    }

    static func snapshot(
        selection: TestAuthoringResolvedSelection,
        selectedPreviewPhaseID: String?
    ) throws -> TestAuthoringSnapshot {
        try snapshot(
            profileContext: bundledSeedProfileContext(),
            selection: selection,
            selectedPreviewPhaseID: selectedPreviewPhaseID
        )
    }

    private static func optionalString(_ view: ScreenUTF8View) -> String? {
        let value = string(view)
        return value.isEmpty ? nil : value
    }

    static func apply(
        _ intent: TestControlIntent,
        to selection: TestAuthoringResolvedSelection,
        profileContext: RustTestAuthoringProfileContext
    ) throws -> TestAuthoringResolvedSelection {
        switch intent {
        case let .setChoice(controlID, optionID):
            return try withRawSelection(selection) { rawSelection in
                try withUTF8View(controlID) { controlView in
                    try withUTF8View(optionID) { optionView in
                        var output = ScreenTestAuthoringSelectionV23()
                        var error: UnsafePointer<CChar>?
                        guard screen_test_authoring_apply_choice_with_profiles(
                            profileContext.handle, rawSelection,
                            controlView, optionView, &output, &error
                        ) else {
                            throw TestAuthoringCoordinatorError.bridge(
                                error.map(String.init(cString:))
                                    ?? "Rust rechazó la selección de Test."
                            )
                        }
                        return try resolved(output)
                    }
                }
            }
        case let .setScalar(controlID, value):
            return try withRawSelection(selection) { rawSelection in
                try withUTF8View(controlID) { controlView in
                    var output = ScreenTestAuthoringSelectionV23()
                    var error: UnsafePointer<CChar>?
                    guard screen_test_authoring_apply_scalar_with_profiles(
                        profileContext.handle, rawSelection,
                        controlView, Float(value), &output, &error
                    ) else {
                        throw TestAuthoringCoordinatorError.bridge(
                            error.map(String.init(cString:))
                                ?? "Rust rechazó el valor de Test."
                        )
                    }
                    return try resolved(output)
                }
            }
        case let .setToggle(controlID, value):
            return try withRawSelection(selection) { rawSelection in
                try withUTF8View(controlID) { controlView in
                    var output = ScreenTestAuthoringSelectionV23()
                    var error: UnsafePointer<CChar>?
                    guard screen_test_authoring_apply_toggle_with_profiles(
                        profileContext.handle, rawSelection,
                        controlView, value, &output, &error
                    ) else {
                        throw TestAuthoringCoordinatorError.bridge(
                            error.map(String.init(cString:))
                                ?? "Rust rechazó el interruptor de Test."
                        )
                    }
                    return try resolved(output)
                }
            }
        case .selectPhase, .reset, .performAction:
            throw TestAuthoringCoordinatorError.unsupportedIntent
        }
    }


    static func apply(
        _ intent: TestControlIntent,
        to selection: TestAuthoringResolvedSelection
    ) throws -> TestAuthoringResolvedSelection {
        try apply(
            intent, to: selection,
            profileContext: bundledSeedProfileContext()
        )
    }

    private static func controlDescriptor(
        descriptor: OpaquePointer,
        phaseIndex: Int,
        controlIndex: Int
    ) throws -> TestControlDescriptor {
        var raw = ScreenTestControlDescriptorV5()
        guard screen_test_page_control_descriptor(
            descriptor, phaseIndex, controlIndex, &raw
        ) else {
            throw TestAuthoringCoordinatorError.malformedDescriptor(
                "Rust no publicó el control \(phaseIndex):\(controlIndex)."
            )
        }
        switch raw.kind {
        case 0:
            let count = screen_test_page_choice_option_count(
                descriptor, phaseIndex, controlIndex
            )
            let options = try (0..<count).map { optionIndex in
                var option = ScreenTestChoiceOptionV2()
                guard screen_test_page_choice_option(
                    descriptor, phaseIndex, controlIndex, optionIndex, &option
                ) else {
                    throw TestAuthoringCoordinatorError.malformedDescriptor(
                        "Rust no publicó una opción de Test."
                    )
                }
                return TestChoiceOption(id: string(option.id), label: string(option.label))
            }
            return .choice(.init(
                id: string(raw.id),
                label: string(raw.label),
                options: options,
                selectedID: string(raw.selected_id),
                resetID: string(raw.reset_id)
            ))
        case 1:
            return .scalar(.init(
                id: string(raw.id),
                label: string(raw.label),
                value: Double(raw.value),
                resetValue: Double(raw.reset_value),
                minimum: Double(raw.minimum),
                maximum: Double(raw.maximum),
                step: Double(raw.step),
                sliderVisible: raw.slider_visible,
                unit: string(raw.unit)
            ))
        case 2:
            return .toggle(.init(
                id: string(raw.id),
                label: string(raw.label),
                value: raw.value != 0,
                resetValue: raw.reset_value != 0
            ))
        case 3:
            return .action(.init(id: string(raw.id), label: string(raw.label)))
        default:
            throw TestAuthoringCoordinatorError.malformedDescriptor(
                "Rust publicó un tipo de control desconocido."
            )
        }
    }

    private static func previewControlDescriptor(
        descriptor: OpaquePointer,
        controlIndex: Int
    ) throws -> TestControlDescriptor {
        var raw = ScreenTestControlDescriptorV5()
        guard screen_test_page_preview_control_descriptor(
            descriptor, controlIndex, &raw
        ) else {
            throw TestAuthoringCoordinatorError.malformedDescriptor(
                "Rust no publicó el control de Preview \(controlIndex)."
            )
        }
        guard raw.kind == 0 else {
            throw TestAuthoringCoordinatorError.malformedDescriptor(
                "El control de Preview debe ser una selección."
            )
        }
        let options = try (0..<screen_test_page_preview_choice_option_count(
            descriptor, controlIndex
        )).map { optionIndex in
            var option = ScreenTestChoiceOptionV2()
            guard screen_test_page_preview_choice_option(
                descriptor, controlIndex, optionIndex, &option
            ) else {
                throw TestAuthoringCoordinatorError.malformedDescriptor(
                    "Rust no publicó una opción de Preview."
                )
            }
            return TestChoiceOption(id: string(option.id), label: string(option.label))
        }
        return .choice(.init(
            id: string(raw.id),
            label: string(raw.label),
            options: options,
            selectedID: string(raw.selected_id),
            resetID: string(raw.reset_id)
        ))
    }

    private static func resolved(
        _ raw: ScreenTestAuthoringSelectionV23
    ) throws -> TestAuthoringResolvedSelection {
        TestAuthoringResolvedSelection(
            inputTransformID: string(raw.input_transform_id),
            outputSignalID: string(raw.output_signal_id),
            deviceID: string(raw.device_id),
            colorModeID: string(raw.color_mode_id),
            deviceEOTFGamma: Double(raw.device_eotf_gamma),
            whiteLuminanceNits: Double(raw.white_luminance_nits),
            placementID: string(raw.placement_id),
            previewQualityID: string(raw.preview_quality_id),
            frameRate: try ExactFrameRate(
                numerator: raw.frame_rate_numerator,
                denominator: raw.frame_rate_denominator
            ),
            sourceExposureEV: Double(raw.source_exposure_ev),
            sourceContrast: Double(raw.source_contrast),
            sourceSaturation: Double(raw.source_saturation),
            sourceTemperatureKelvin: Double(raw.source_temperature_kelvin),
            sourceTint: Double(raw.source_tint),
            subpixelGeometryAmount: Double(raw.subpixel_geometry_amount),
            moireIntensity: Double(raw.moire_intensity),
            moireSaturation: Double(raw.moire_saturation),
            moireFilterStrength: Double(raw.moire_filter_strength),
            panelUniformityAmount: Double(raw.panel_uniformity_amount),
            panelLightSpreadAmount: Double(raw.panel_light_spread_amount),
            capturePresetID: string(raw.capture_preset_id),
            captureRasterModeID: string(raw.capture_raster_mode_id),
            lensEvaluationModelID: string(raw.lens_evaluation_model_id),
            geometryModeID: string(raw.geometry_mode_id),
            cameraDistanceMeters: Double(raw.camera_distance_meters),
            cameraOrbitXDegrees: Double(raw.camera_orbit_x_degrees),
            cameraOrbitYDegrees: Double(raw.camera_orbit_y_degrees),
            cameraPositionXMeters: Double(raw.camera_position_x_meters),
            cameraPositionYMeters: Double(raw.camera_position_y_meters),
            cameraPositionZMeters: Double(raw.camera_position_z_meters),
            cameraRotationXDegrees: Double(raw.camera_rotation_x_degrees),
            cameraRotationYDegrees: Double(raw.camera_rotation_y_degrees),
            cameraRotationZDegrees: Double(raw.camera_rotation_z_degrees),
            screenPositionXMeters: Double(raw.screen_position_x_meters),
            screenPositionYMeters: Double(raw.screen_position_y_meters),
            screenPositionZMeters: Double(raw.screen_position_z_meters),
            screenRotationXDegrees: Double(raw.screen_rotation_x_degrees),
            screenYawDegrees: Double(raw.screen_yaw_degrees),
            screenRotationZDegrees: Double(raw.screen_rotation_z_degrees),
            coverGlassPresetID: string(raw.cover_glass_preset_id),
            coverGlassAmount: Double(raw.cover_glass_amount),
            coverAgMicrotextureAmount: Double(raw.cover_ag_microtexture_amount),
            coverThicknessMillimeters: Double(raw.cover_thickness_millimeters),
            coverRefractiveIndex: Double(raw.cover_refractive_index),
            coverAREfficiency: Double(raw.cover_ar_efficiency),
            coverAbsorptionRGB: [Double(raw.cover_absorption_rgb.0), Double(raw.cover_absorption_rgb.1), Double(raw.cover_absorption_rgb.2)],
            coverRoughness: Double(raw.cover_roughness),
            coverHaze: Double(raw.cover_haze),
            coverAgRMSSlope: Double(raw.cover_ag_rms_slope),
            coverAgCorrelationMicrometers: Double(raw.cover_ag_correlation_micrometers),
            coverAgAnisotropy: Double(raw.cover_ag_anisotropy),
            environmentSourceID: string(raw.environment_source_id),
            environmentAmount: Double(raw.environment_amount),
            environmentRotationXDegrees: Double(raw.environment_rotation_x_degrees),
            environmentRotationYDegrees: Double(raw.environment_rotation_y_degrees),
            environmentAnchorLongitudeDegrees: Double(raw.environment_anchor_longitude_degrees),
            environmentAnchorLatitudeDegrees: Double(raw.environment_anchor_latitude_degrees),
            environmentTangentTransform: [
                Double(raw.environment_tangent_transform.0),
                Double(raw.environment_tangent_transform.1),
                Double(raw.environment_tangent_transform.2),
                Double(raw.environment_tangent_transform.3),
            ],
            environmentExposureEV: Double(raw.environment_exposure_ev),
            environmentContrast: Double(raw.environment_contrast),
            environmentSaturation: Double(raw.environment_saturation),
            environmentTemperatureKelvin: Double(raw.environment_temperature_kelvin),
            environmentTint: Double(raw.environment_tint),
            environmentProjectionID: string(raw.environment_projection_id),
            environmentSphereCenterXMeters: Double(raw.environment_sphere_center_x_meters),
            environmentSphereCenterYMeters: Double(raw.environment_sphere_center_y_meters),
            environmentSphereCenterZMeters: Double(raw.environment_sphere_center_z_meters),
            environmentSphereRadiusMeters: Double(raw.environment_sphere_radius_meters),
            coverGlowAmount: Double(raw.cover_glow_amount),
            coverGlowIntensity: Double(raw.cover_glow_intensity),
            coverGlowRadiusMillimeters: Double(raw.cover_glow_radius_millimeters),
            coverGlowThresholdRelativeWhite: Double(raw.cover_glow_threshold_relative_white),
            coverGlowExteriorIntensity: Double(raw.cover_glow_exterior_intensity),
            lensPresetID: string(raw.lens_preset_id),
            focalLengthMillimeters: Double(raw.focal_length_millimeters),
            lensAmount: Double(raw.lens_amount),
            autofocusEnabled: raw.autofocus_enabled,
            autofocusTargetU: Double(raw.autofocus_target_u),
            autofocusTargetV: Double(raw.autofocus_target_v),
            focusDistanceMeters: Double(raw.focus_distance_meters),
            fStop: Double(raw.f_stop),
            exposureTimeSeconds: Double(raw.exposure_time_seconds),
            shutterMotionAmount: Double(raw.shutter_motion_amount),
            computationalCharacterStrength: Double(raw.computational_character_strength),
            computationalExposureCount: Double(raw.computational_exposure_count),
            computationalBracketSpacingStops: Double(raw.computational_bracket_spacing_stops),
            sensorBloomAmount: Double(raw.sensor_bloom_amount),
            sensorBloomCrosstalkFraction: Double(raw.sensor_bloom_crosstalk_fraction),
            sensorBloomOverflowTransferFraction: Double(
                raw.sensor_bloom_overflow_transfer_fraction
            ),
            sensorNoiseAmount: Double(raw.sensor_noise_amount),
            cameraLookExposureEV: Double(raw.camera_look_exposure_ev),
            cameraLookContrast: Double(raw.camera_look_contrast),
            cameraLookSaturation: Double(raw.camera_look_saturation),
            cameraLookTemperatureKelvin: Double(raw.camera_look_temperature_kelvin),
            cameraLookTint: Double(raw.camera_look_tint),
            deviceVfxAlphaModeID: string(raw.device_vfx_alpha_mode_id),
            deliveryPresetID: string(raw.delivery_preset_id),
            deliveryWidth: raw.delivery_width,
            deliveryHeight: raw.delivery_height,
            deliveryPlacementID: string(raw.delivery_placement_id),
            deliveryBackgroundID: string(raw.delivery_background_id),
            recordingOutputTransformID: string(raw.recording_output_transform_id),
            recordingProfileID: string(raw.recording_profile_id),
            recordingCharacter: Double(raw.recording_character)
        )
    }

    private static func withRawSelection<Result>(
        _ selection: TestAuthoringResolvedSelection,
        _ body: (UnsafePointer<ScreenTestAuthoringSelectionV23>) throws -> Result
    ) throws -> Result {
        try withUTF8View(selection.inputTransformID) { inputView in
            try withUTF8View(selection.outputSignalID) { outputView in
            try withUTF8View(selection.deviceID) { deviceView in
                try withUTF8View(selection.colorModeID) { modeView in
                    try withUTF8View(selection.placementID) { placementView in
                        try withUTF8View(selection.previewQualityID) { qualityView in
                            try withUTF8View(selection.capturePresetID) { captureView in
                            try withUTF8View(selection.captureRasterModeID) { captureRasterView in
                            try withUTF8View(selection.lensEvaluationModelID) { lensEvaluationModelView in
                                try withUTF8View(selection.geometryModeID) { geometryModeView in
                                try withUTF8View(selection.coverGlassPresetID) { coverView in
                                    try withUTF8View(selection.environmentSourceID) { environmentView in
                                            try withUTF8View(selection.lensPresetID) { lensView in
                                            try withUTF8View(selection.deliveryPlacementID) { deliveryPlacementView in
                                            try withUTF8View(selection.deliveryBackgroundID) { deliveryBackgroundView in
                                            try withUTF8View(selection.deliveryPresetID) { deliveryPresetView in
                                            try withUTF8View(selection.recordingOutputTransformID) { recordingOutputView in
                                                try withUTF8View(selection.recordingProfileID) { recordingProfileView in
                                                try withUTF8View(selection.environmentProjectionID) { environmentProjectionView in
                                                try withUTF8View(selection.deviceVfxAlphaModeID) { deviceVfxAlphaModeView in
                                                    var raw = ScreenTestAuthoringSelectionV23()
                                            raw.abi_version = SCREEN_TEST_AUTHORING_ABI_VERSION
                                            raw.input_transform_id = inputView
                                            raw.output_signal_id = outputView
                                            raw.device_id = deviceView
                                            raw.color_mode_id = modeView
                                            raw.device_eotf_gamma = Float(selection.deviceEOTFGamma)
                                            raw.white_luminance_nits = Float(selection.whiteLuminanceNits)
                                            raw.placement_id = placementView
                                            raw.preview_quality_id = qualityView
                                            raw.frame_rate_numerator = selection.frameRate.numerator
                                            raw.frame_rate_denominator = selection.frameRate.denominator
                                            raw.source_exposure_ev = Float(selection.sourceExposureEV)
                                            raw.source_contrast = Float(selection.sourceContrast)
                                            raw.source_saturation = Float(selection.sourceSaturation)
                                            raw.source_temperature_kelvin = Float(selection.sourceTemperatureKelvin)
                                            raw.source_tint = Float(selection.sourceTint)
                                            raw.subpixel_geometry_amount = Float(selection.subpixelGeometryAmount)
                                            raw.moire_intensity = Float(selection.moireIntensity)
                                            raw.moire_saturation = Float(selection.moireSaturation)
                                            raw.moire_filter_strength = Float(selection.moireFilterStrength)
                                            raw.panel_uniformity_amount = Float(selection.panelUniformityAmount)
                                            raw.panel_light_spread_amount = Float(selection.panelLightSpreadAmount)
                                            raw.capture_preset_id = captureView
                                            raw.capture_raster_mode_id = captureRasterView
                                            raw.lens_evaluation_model_id = lensEvaluationModelView
                                            raw.geometry_mode_id = geometryModeView
                                            raw.camera_distance_meters = Float(selection.cameraDistanceMeters)
                                            raw.camera_orbit_x_degrees = Float(selection.cameraOrbitXDegrees)
                                            raw.camera_orbit_y_degrees = Float(selection.cameraOrbitYDegrees)
                                            raw.camera_position_x_meters = Float(selection.cameraPositionXMeters)
                                            raw.camera_position_y_meters = Float(selection.cameraPositionYMeters)
                                            raw.camera_position_z_meters = Float(selection.cameraPositionZMeters)
                                            raw.camera_rotation_x_degrees = Float(selection.cameraRotationXDegrees)
                                            raw.camera_rotation_y_degrees = Float(selection.cameraRotationYDegrees)
                                            raw.camera_rotation_z_degrees = Float(selection.cameraRotationZDegrees)
                                            raw.screen_position_x_meters = Float(selection.screenPositionXMeters)
                                            raw.screen_position_y_meters = Float(selection.screenPositionYMeters)
                                            raw.screen_position_z_meters = Float(selection.screenPositionZMeters)
                                            raw.screen_rotation_x_degrees = Float(selection.screenRotationXDegrees)
                                            raw.screen_yaw_degrees = Float(selection.screenYawDegrees)
                                            raw.screen_rotation_z_degrees = Float(selection.screenRotationZDegrees)
                                            raw.cover_glass_preset_id = coverView
                                            raw.cover_glass_amount = Float(selection.coverGlassAmount)
                                            raw.cover_ag_microtexture_amount = Float(
                                                selection.coverAgMicrotextureAmount
                                            )
                                            raw.cover_thickness_millimeters = Float(selection.coverThicknessMillimeters)
                                            raw.cover_refractive_index = Float(selection.coverRefractiveIndex)
                                            raw.cover_ar_efficiency = Float(selection.coverAREfficiency)
                                            raw.cover_absorption_rgb = (
                                                Float(selection.coverAbsorptionRGB[0]),
                                                Float(selection.coverAbsorptionRGB[1]),
                                                Float(selection.coverAbsorptionRGB[2])
                                            )
                                            raw.cover_roughness = Float(selection.coverRoughness)
                                            raw.cover_haze = Float(selection.coverHaze)
                                            raw.cover_ag_rms_slope = Float(selection.coverAgRMSSlope)
                                            raw.cover_ag_correlation_micrometers = Float(selection.coverAgCorrelationMicrometers)
                                            raw.cover_ag_anisotropy = Float(selection.coverAgAnisotropy)
                                            raw.environment_source_id = environmentView
                                            raw.environment_amount = Float(selection.environmentAmount)
                                            raw.environment_rotation_x_degrees = Float(
                                                selection.environmentRotationXDegrees
                                            )
                                            raw.environment_rotation_y_degrees = Float(
                                                selection.environmentRotationYDegrees
                                            )
                                            raw.environment_anchor_longitude_degrees = Float(
                                                selection.environmentAnchorLongitudeDegrees
                                            )
                                            raw.environment_anchor_latitude_degrees = Float(
                                                selection.environmentAnchorLatitudeDegrees
                                            )
                                            raw.environment_tangent_transform = (
                                                Float(selection.environmentTangentTransform[0]),
                                                Float(selection.environmentTangentTransform[1]),
                                                Float(selection.environmentTangentTransform[2]),
                                                Float(selection.environmentTangentTransform[3])
                                            )
                                            raw.environment_exposure_ev = Float(
                                                selection.environmentExposureEV
                                            )
                                            raw.environment_contrast = Float(selection.environmentContrast)
                                            raw.environment_saturation = Float(selection.environmentSaturation)
                                            raw.environment_temperature_kelvin = Float(selection.environmentTemperatureKelvin)
                                            raw.environment_tint = Float(selection.environmentTint)
                                            raw.environment_projection_id = environmentProjectionView
                                            raw.environment_sphere_center_x_meters = Float(
                                                selection.environmentSphereCenterXMeters
                                            )
                                            raw.environment_sphere_center_y_meters = Float(
                                                selection.environmentSphereCenterYMeters
                                            )
                                            raw.environment_sphere_center_z_meters = Float(
                                                selection.environmentSphereCenterZMeters
                                            )
                                            raw.environment_sphere_radius_meters = Float(selection.environmentSphereRadiusMeters)
                                            raw.cover_glow_amount = Float(selection.coverGlowAmount)
                                            raw.cover_glow_intensity = Float(selection.coverGlowIntensity)
                                            raw.cover_glow_radius_millimeters = Float(selection.coverGlowRadiusMillimeters)
                                            raw.cover_glow_threshold_relative_white = Float(selection.coverGlowThresholdRelativeWhite)
                                            raw.cover_glow_exterior_intensity = Float(selection.coverGlowExteriorIntensity)
                                            raw.lens_preset_id = lensView
                                            raw.focal_length_millimeters = Float(
                                                selection.focalLengthMillimeters
                                            )
                                            raw.lens_amount = Float(selection.lensAmount)
                                            raw.autofocus_enabled = selection.autofocusEnabled
                                            raw.autofocus_target_u = Float(selection.autofocusTargetU)
                                            raw.autofocus_target_v = Float(selection.autofocusTargetV)
                                            raw.focus_distance_meters = Float(selection.focusDistanceMeters)
                                            raw.f_stop = Float(selection.fStop)
                                            raw.exposure_time_seconds = Float(selection.exposureTimeSeconds)
                                            raw.shutter_motion_amount = Float(selection.shutterMotionAmount)
                                            raw.computational_character_strength = Float(selection.computationalCharacterStrength)
                                            raw.computational_exposure_count = Float(selection.computationalExposureCount)
                                            raw.computational_bracket_spacing_stops = Float(selection.computationalBracketSpacingStops)
                                            raw.sensor_bloom_amount = Float(selection.sensorBloomAmount)
                                            raw.sensor_bloom_crosstalk_fraction = Float(
                                                selection.sensorBloomCrosstalkFraction
                                            )
                                            raw.sensor_bloom_overflow_transfer_fraction = Float(
                                                selection.sensorBloomOverflowTransferFraction
                                            )
                                            raw.sensor_noise_amount = Float(selection.sensorNoiseAmount)
                                            raw.camera_look_exposure_ev = Float(selection.cameraLookExposureEV)
                                            raw.camera_look_contrast = Float(selection.cameraLookContrast)
                                            raw.camera_look_saturation = Float(selection.cameraLookSaturation)
                                            raw.camera_look_temperature_kelvin = Float(selection.cameraLookTemperatureKelvin)
                                            raw.camera_look_tint = Float(selection.cameraLookTint)
                                            raw.device_vfx_alpha_mode_id = deviceVfxAlphaModeView
                                            raw.delivery_preset_id = deliveryPresetView
                                            raw.delivery_width = selection.deliveryWidth
                                            raw.delivery_height = selection.deliveryHeight
                                            raw.delivery_placement_id = deliveryPlacementView
                                            raw.delivery_background_id = deliveryBackgroundView
                                            raw.recording_output_transform_id = recordingOutputView
                                            raw.recording_profile_id = recordingProfileView
                                            raw.recording_character = Float(selection.recordingCharacter)
                                                    return try withUnsafePointer(to: &raw, body)
                                                }
                                                }
                                                }
                                                }
                                                }
                                                }
                                                }
                                            }
                                    }
                                }
                            }
                            }
                        }
                    }
                }
            }
        }
        }
        }
        }
    }

    private static func withUTF8View<Result>(
        _ value: String,
        _ body: (ScreenUTF8View) throws -> Result
    ) rethrows -> Result {
        let bytes = Array(value.utf8)
        return try bytes.withUnsafeBufferPointer { storage in
            try body(ScreenUTF8View(bytes: storage.baseAddress, count: storage.count))
        }
    }

    private static func string(_ view: ScreenUTF8View) -> String {
        guard let bytes = view.bytes, view.count > 0 else { return "" }
        return String(
            decoding: UnsafeBufferPointer(start: bytes, count: view.count),
            as: UTF8.self
        )
    }
}
