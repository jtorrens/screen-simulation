import Foundation
import ScreenPhysicalBridge
import ScreenSimulationPresentation

enum TestPreviewResultKind: UInt32, Sendable {
    case sourceACEScg = 0
    case feederSignal = 1
    case deviceInterpretation = 2
    case panelStructure = 3
    case panelUniformity = 4
    case panelLightSpread = 5
    case relativeGeometry = 6
    case coverEnvironment = 7
    case coverGlow = 8
    case lensProjection = 9
    case shutterExposure = 10
    case computationalCapture = 11
    case sensorBloom = 12
    case sensorCfa = 13
    case sensorNoise = 14
    case developDemosaic = 15
    case cameraRenderingIntent = 16
    case recordingOutput = 17
    case recordingCodec = 18
}

struct TestAuthoringResolvedSelection: Equatable, Sendable {
    let inputTransformID: String
    let outputSignalID: String
    let deviceID: String
    let colorModeID: String
    let deviceEOTFGamma: Double
    let whiteLuminanceNits: Double
    let placementID: String
    let previewQualityID: String
    var frameRate: Double
    let subpixelGeometryAmount: Double
    let panelUniformityAmount: Double
    let panelLightSpreadAmount: Double
    let capturePresetID: String
    let geometryModeID: String
    let cameraDistanceMeters: Double
    let cameraOrbitXDegrees: Double
    let cameraOrbitYDegrees: Double
    let cameraPositionXMeters: Double
    let cameraPositionYMeters: Double
    let cameraPositionZMeters: Double
    let cameraRotationXDegrees: Double
    let cameraRotationYDegrees: Double
    let cameraRotationZDegrees: Double
    let screenPositionXMeters: Double
    let screenPositionYMeters: Double
    let screenPositionZMeters: Double
    let screenRotationXDegrees: Double
    let screenYawDegrees: Double
    let screenRotationZDegrees: Double
    let coverGlassPresetID: String
    let coverGlassAmount: Double
    let coverAgMicrotextureAmount: Double
    let environmentPresetID: String
    let environmentAmount: Double
    let coverGlowAmount: Double
    let lensPresetID: String
    let lensAmount: Double
    let autofocusEnabled: Bool
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
    let recordingOutputTransformID: String
    let recordingProfileID: String
    let recordingCharacter: Double
}

struct TestAuthoringSnapshot: Sendable {
    let presentation: TestPagePresentation
    let previewResultByPhaseID: [String: TestPreviewResultKind]
    let resolvedSelection: TestAuthoringResolvedSelection
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

enum RustTestAuthoringCoordinator {
    static func defaultSelection(
        inputTransformID: String,
        deviceID: String,
        frameRate: Double
    ) throws -> TestAuthoringResolvedSelection {
        try withUTF8View(inputTransformID) { inputView in
            try withUTF8View(deviceID) { deviceView in
                var output = ScreenTestAuthoringSelectionV15()
                var error: UnsafePointer<CChar>?
                guard screen_test_authoring_default_selection(
                    inputView, deviceView, Float(frameRate), &output, &error
                ) else {
                    throw TestAuthoringCoordinatorError.bridge(
                        error.map(String.init(cString:))
                            ?? "Rust no pudo crear la selección inicial de Test."
                    )
                }
                return resolved(output)
            }
        }
    }

    static func snapshot(
        selection: TestAuthoringResolvedSelection,
        selectedPreviewPhaseID: String?
    ) throws -> TestAuthoringSnapshot {
        try withRawSelection(selection) { rawSelection in
            var error: UnsafePointer<CChar>?
            guard let descriptor = screen_test_page_descriptor_create(rawSelection, &error) else {
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
            var previewResults: [String: TestPreviewResultKind] = [:]
            phases.reserveCapacity(phaseCount)
            for phaseIndex in 0..<phaseCount {
                var rawPhase = ScreenTestPhaseDescriptorV3()
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
                    controls.append(try controlDescriptor(
                        descriptor: descriptor,
                        phaseIndex: phaseIndex,
                        controlIndex: controlIndex
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
                    sections: sections
                ))
                previewResults[phaseID] = previewResult
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
            return TestAuthoringSnapshot(
                presentation: try TestPagePresentation(
                    phases: phases,
                    selectedPhaseID: selectedPhaseID,
                    previewControls: previewControls
                ),
                previewResultByPhaseID: previewResults,
                resolvedSelection: selection
            )
        }
    }

    private static func optionalString(_ view: ScreenUTF8View) -> String? {
        let value = string(view)
        return value.isEmpty ? nil : value
    }

    static func apply(
        _ intent: TestControlIntent,
        to selection: TestAuthoringResolvedSelection
    ) throws -> TestAuthoringResolvedSelection {
        switch intent {
        case let .setChoice(controlID, optionID):
            return try withRawSelection(selection) { rawSelection in
                try withUTF8View(controlID) { controlView in
                    try withUTF8View(optionID) { optionView in
                        var output = ScreenTestAuthoringSelectionV15()
                        var error: UnsafePointer<CChar>?
                        guard screen_test_authoring_apply_choice(
                            rawSelection, controlView, optionView, &output, &error
                        ) else {
                            throw TestAuthoringCoordinatorError.bridge(
                                error.map(String.init(cString:))
                                    ?? "Rust rechazó la selección de Test."
                            )
                        }
                        return resolved(output)
                    }
                }
            }
        case let .setScalar(controlID, value):
            return try withRawSelection(selection) { rawSelection in
                try withUTF8View(controlID) { controlView in
                    var output = ScreenTestAuthoringSelectionV15()
                    var error: UnsafePointer<CChar>?
                    guard screen_test_authoring_apply_scalar(
                        rawSelection, controlView, Float(value), &output, &error
                    ) else {
                        throw TestAuthoringCoordinatorError.bridge(
                            error.map(String.init(cString:))
                                ?? "Rust rechazó el valor de Test."
                        )
                    }
                    return resolved(output)
                }
            }
        case let .setToggle(controlID, value):
            return try withRawSelection(selection) { rawSelection in
                try withUTF8View(controlID) { controlView in
                    var output = ScreenTestAuthoringSelectionV15()
                    var error: UnsafePointer<CChar>?
                    guard screen_test_authoring_apply_toggle(
                        rawSelection, controlView, value, &output, &error
                    ) else {
                        throw TestAuthoringCoordinatorError.bridge(
                            error.map(String.init(cString:))
                                ?? "Rust rechazó el interruptor de Test."
                        )
                    }
                    return resolved(output)
                }
            }
        case .selectPhase, .performAction:
            throw TestAuthoringCoordinatorError.unsupportedIntent
        }
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
        _ raw: ScreenTestAuthoringSelectionV15
    ) -> TestAuthoringResolvedSelection {
        TestAuthoringResolvedSelection(
            inputTransformID: string(raw.input_transform_id),
            outputSignalID: string(raw.output_signal_id),
            deviceID: string(raw.device_id),
            colorModeID: string(raw.color_mode_id),
            deviceEOTFGamma: Double(raw.device_eotf_gamma),
            whiteLuminanceNits: Double(raw.white_luminance_nits),
            placementID: string(raw.placement_id),
            previewQualityID: string(raw.preview_quality_id),
            frameRate: Double(raw.frame_rate),
            subpixelGeometryAmount: Double(raw.subpixel_geometry_amount),
            panelUniformityAmount: Double(raw.panel_uniformity_amount),
            panelLightSpreadAmount: Double(raw.panel_light_spread_amount),
            capturePresetID: string(raw.capture_preset_id),
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
            environmentPresetID: string(raw.environment_preset_id),
            environmentAmount: Double(raw.environment_amount),
            coverGlowAmount: Double(raw.cover_glow_amount),
            lensPresetID: string(raw.lens_preset_id),
            lensAmount: Double(raw.lens_amount),
            autofocusEnabled: raw.autofocus_enabled,
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
            recordingOutputTransformID: string(raw.recording_output_transform_id),
            recordingProfileID: string(raw.recording_profile_id),
            recordingCharacter: Double(raw.recording_character)
        )
    }

    private static func withRawSelection<Result>(
        _ selection: TestAuthoringResolvedSelection,
        _ body: (UnsafePointer<ScreenTestAuthoringSelectionV15>) throws -> Result
    ) throws -> Result {
        try withUTF8View(selection.inputTransformID) { inputView in
            try withUTF8View(selection.outputSignalID) { outputView in
            try withUTF8View(selection.deviceID) { deviceView in
                try withUTF8View(selection.colorModeID) { modeView in
                    try withUTF8View(selection.placementID) { placementView in
                        try withUTF8View(selection.previewQualityID) { qualityView in
                            try withUTF8View(selection.capturePresetID) { captureView in
                                try withUTF8View(selection.geometryModeID) { geometryModeView in
                                try withUTF8View(selection.coverGlassPresetID) { coverView in
                                    try withUTF8View(selection.environmentPresetID) { environmentView in
                                        try withUTF8View(selection.lensPresetID) { lensView in
                                            try withUTF8View(selection.recordingOutputTransformID) { recordingOutputView in
                                                try withUTF8View(selection.recordingProfileID) { recordingProfileView in
                                                    var raw = ScreenTestAuthoringSelectionV15()
                                            raw.abi_version = SCREEN_TEST_AUTHORING_ABI_VERSION
                                            raw.input_transform_id = inputView
                                            raw.output_signal_id = outputView
                                            raw.device_id = deviceView
                                            raw.color_mode_id = modeView
                                            raw.device_eotf_gamma = Float(selection.deviceEOTFGamma)
                                            raw.white_luminance_nits = Float(selection.whiteLuminanceNits)
                                            raw.placement_id = placementView
                                            raw.preview_quality_id = qualityView
                                            raw.frame_rate = Float(selection.frameRate)
                                            raw.subpixel_geometry_amount = Float(selection.subpixelGeometryAmount)
                                            raw.panel_uniformity_amount = Float(selection.panelUniformityAmount)
                                            raw.panel_light_spread_amount = Float(selection.panelLightSpreadAmount)
                                            raw.capture_preset_id = captureView
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
                                            raw.environment_preset_id = environmentView
                                            raw.environment_amount = Float(selection.environmentAmount)
                                            raw.cover_glow_amount = Float(selection.coverGlowAmount)
                                            raw.lens_preset_id = lensView
                                            raw.lens_amount = Float(selection.lensAmount)
                                            raw.autofocus_enabled = selection.autofocusEnabled
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
