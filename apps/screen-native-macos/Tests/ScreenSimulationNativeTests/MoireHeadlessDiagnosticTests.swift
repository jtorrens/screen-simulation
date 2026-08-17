import CryptoKit
import CoreGraphics
import Foundation
import Metal
import StudioColor
import Testing
@testable import ScreenSimulationNative

@Test @MainActor func optionalMoireHeadlessDiagnosticIsDeterministic() async throws {
    let processSettings = ProcessInfo.processInfo.environment
    guard let fixturePath = processSettings["SCREEN_MOIRE_FIXTURE_PATH"] else {
        return
    }
    let allowedInvocationSettings: Set<String> = [
        "SCREEN_MOIRE_FIXTURE_PATH",
        "SCREEN_MOIRE_RESOURCE_ROOT",
        "SCREEN_MOIRE_DIAGNOSTIC_DIR",
        "SCREEN_MOIRE_DIAGNOSTIC_IDEAL_FULL_RGB",
        "SCREEN_MOIRE_RECORDING_DIAGNOSTIC",
        "SCREEN_MOIRE_PHASE_ISOLATION",
        "SCREEN_MOIRE_ZERO_DOWNSTREAM_ISOLATION",
        "SCREEN_MOIRE_SETTINGS_DOCUMENT_PATH",
        "SCREEN_MOIRE_FORCE_LENS_EVALUATION_MODEL",
        "SCREEN_MOIRE_FORCE_INTENSITY",
        "SCREEN_MOIRE_FORCE_BASELINE_INTERMEDIATE",
    ]
    let unexpectedInvocationSettings = Set(processSettings.keys.filter {
        ($0.hasPrefix("SCREEN_MOIRE_") && !allowedInvocationSettings.contains($0))
            || $0.hasPrefix("SCREEN_DIAGNOSTIC_")
    })
    #expect(unexpectedInvocationSettings.isEmpty)
    guard unexpectedInvocationSettings.isEmpty else { return }
    let resourceRoot = try #require(processSettings["SCREEN_MOIRE_RESOURCE_ROOT"])
    let fixture = try VfxReferenceFixture.load(
        from: URL(fileURLWithPath: fixturePath),
        repositoryRoot: moireRepositoryRoot(),
        resourceRoot: URL(fileURLWithPath: resourceRoot, isDirectory: true)
    )
    VfxReferenceFixtureRuntime.current = fixture
    let injectedKeys = Array(fixture.settings.keys)
    defer {
        for key in injectedKeys { unsetenv(key) }
        VfxReferenceFixtureRuntime.current = nil
    }
    for (key, value) in fixture.settings {
        setenv(key, value, 1)
    }
    if let forcedIntermediate = processSettings["SCREEN_MOIRE_FORCE_BASELINE_INTERMEDIATE"] {
        setenv("SCREEN_MOIRE_BASELINE_INTERMEDIATE", forcedIntermediate, 1)
    }
    let expectedHash = processSettings["SCREEN_MOIRE_SETTINGS_DOCUMENT_PATH"] == nil
        ? fixture.acceptedOutput?.pixelRGBA8SHA256
        : nil
    let deviceID = try #require(ProcessInfo.processInfo.environment["SCREEN_MOIRE_DEVICE_ID"])
    let environmentSourcePath = ProcessInfo.processInfo.environment[
        "SCREEN_MOIRE_ENVIRONMENT_SOURCE_PATH"
    ]
    let fixtureImported: PhysicalSettingsExchange.Imported
    do {
        var device = try #require(try RustDeviceCatalog.builtIns().first { $0.id == deviceID })
        if let width = ProcessInfo.processInfo.environment["SCREEN_MOIRE_DEVICE_WIDTH"]
            .flatMap(Int.init),
           let height = ProcessInfo.processInfo.environment["SCREEN_MOIRE_DEVICE_HEIGHT"]
            .flatMap(Int.init)
        {
            device.nativeWidth = width
            device.nativeHeight = height
        }
        if let white = ProcessInfo.processInfo.environment["SCREEN_MOIRE_WHITE_NITS"]
            .flatMap(Double.init)
        {
            device.whiteLevelNits = white
        }
        device.colorModeID = try #require(
            ProcessInfo.processInfo.environment["SCREEN_MOIRE_COLOR_MODE_ID"]
        )
        if let authoredBlackMatrix = ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_BLACK_MATRIX_FRACTION"
        ] {
            let blackMatrix = try #require(Double(authoredBlackMatrix))
            try #require(blackMatrix >= 0 && blackMatrix < 1)
            device.blackMatrixFraction = blackMatrix
        }
        let coverID = try #require(ProcessInfo.processInfo.environment["SCREEN_MOIRE_COVER_ID"])
        var cover = try #require(try RustCoverGlassCatalog.builtIns().first {
            $0.id == coverID
        })
        cover.characterStrength = try moireRequiredDouble("SCREEN_MOIRE_COVER_CHARACTER_STRENGTH")
        cover.thicknessMillimeters = try moireRequiredDouble(
            "SCREEN_MOIRE_COVER_THICKNESS_MILLIMETERS"
        )
        cover.refractiveIndex = try moireRequiredDouble(
            "SCREEN_MOIRE_COVER_REFRACTIVE_INDEX"
        )
        cover.antiReflectiveEfficiency = try moireRequiredDouble(
            "SCREEN_MOIRE_COVER_ANTI_REFLECTIVE_EFFICIENCY"
        )
        cover.absorptionPerMillimeter = try [
            moireRequiredDouble("SCREEN_MOIRE_COVER_ABSORPTION_R"),
            moireRequiredDouble("SCREEN_MOIRE_COVER_ABSORPTION_G"),
            moireRequiredDouble("SCREEN_MOIRE_COVER_ABSORPTION_B"),
        ]
        cover.roughness = try moireRequiredDouble("SCREEN_MOIRE_COVER_ROUGHNESS")
        cover.haze = try moireRequiredDouble("SCREEN_MOIRE_COVER_HAZE")
        cover.agMicrotextureCharacterStrength = try moireRequiredDouble(
            "SCREEN_MOIRE_COVER_AG_MICROTEXTURE_CHARACTER_STRENGTH"
        )
        cover.agMicrotextureRMSSlope = try moireRequiredDouble(
            "SCREEN_MOIRE_COVER_AG_MICROTEXTURE_RMS_SLOPE"
        )
        cover.agMicrotextureCorrelationLengthMicrometers = try moireRequiredDouble(
            "SCREEN_MOIRE_COVER_AG_MICROTEXTURE_CORRELATION_LENGTH_MICROMETERS"
        )
        cover.agMicrotextureAnisotropy = try moireRequiredDouble(
            "SCREEN_MOIRE_COVER_AG_MICROTEXTURE_ANISOTROPY"
        )
        cover.agMicrotextureSeed = try #require(
            ProcessInfo.processInfo.environment["SCREEN_MOIRE_COVER_AG_MICROTEXTURE_SEED"]
                .flatMap(UInt32.init),
            "Falta el entero VFX obligatorio SCREEN_MOIRE_COVER_AG_MICROTEXTURE_SEED"
        )
        cover.glowCharacterStrength = try moireRequiredDouble(
            "SCREEN_MOIRE_COVER_GLOW_PROFILE_STRENGTH"
        )
        cover.glowScatterFraction = try moireRequiredDouble(
            "SCREEN_MOIRE_COVER_GLOW_SCATTER_FRACTION"
        )
        cover.glowCoreRadiusMillimeters = try moireRequiredDouble(
            "SCREEN_MOIRE_COVER_GLOW_CORE_RADIUS_MILLIMETERS"
        )
        cover.glowTailRadiusMillimeters = try moireRequiredDouble(
            "SCREEN_MOIRE_COVER_GLOW_TAIL_RADIUS_MILLIMETERS"
        )
        cover.glowTailFraction = try moireRequiredDouble(
            "SCREEN_MOIRE_COVER_GLOW_TAIL_FRACTION"
        )
        cover.glowThresholdRelativeWhite = try moireRequiredDouble(
            "SCREEN_MOIRE_COVER_GLOW_THRESHOLD_RELATIVE_WHITE"
        )
        try cover.validate()
        var pipeline = try PhysicalPipelineAuthoringState.seeded(
            device: device,
            coverGlass: cover
        )
        let captureID = try #require(ProcessInfo.processInfo.environment["SCREEN_MOIRE_CAPTURE_ID"])
        let capture = try #require(
            try CapturePresetDefinition.catalog().first { $0.id == captureID }
        )
        let lensID = try #require(
            ProcessInfo.processInfo.environment["SCREEN_MOIRE_LENS_ID"]
        )
        #expect(capture.compatibleLensIDs.contains(lensID))
        let lens = try #require(
            try LensPresetDefinition.catalog().first { $0.id == lensID }
        )
        try capture.applyCamera(
            rasterModeID: capture.defaultRasterModeID,
            to: &pipeline,
            frameRate: 24
        )
        lens.apply(to: &pipeline)
        let captureWidth = ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_CAPTURE_WIDTH"
        ].flatMap(UInt32.init)
        let captureHeight = ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_CAPTURE_HEIGHT"
        ].flatMap(UInt32.init)
        if captureWidth != nil || captureHeight != nil {
            pipeline.sensor.nativeWidth = try #require(captureWidth)
            pipeline.sensor.nativeHeight = try #require(captureHeight)
        }
        if let environmentID = ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_ENVIRONMENT_ID"
        ] {
            guard environmentSourcePath == nil else {
                Issue.record(
                    "SCREEN_MOIRE_ENVIRONMENT_ID y SCREEN_MOIRE_ENVIRONMENT_SOURCE_PATH son excluyentes"
                )
                return
            }
            let environment = try #require(
                try EnvironmentPresetDefinition.catalog().first { $0.id == environmentID }
            )
            environment.apply(to: &pipeline)
        }
        if environmentSourcePath != nil {
            guard let unitRadiance = ProcessInfo.processInfo.environment[
                "SCREEN_MOIRE_ENVIRONMENT_UNIT_RADIANCE_CDM2"
            ].flatMap(Double.init),
                unitRadiance > 0,
                ProcessInfo.processInfo.environment[
                    "SCREEN_MOIRE_ENVIRONMENT_INPUT_TRANSFORM_ID"
                ] != nil
            else {
                Issue.record(
                    "El entorno HDR requiere Input Transform y radiancia cd/m² por unidad explícitos"
                )
                return
            }
            pipeline.environment.sourceKind = 1
            pipeline.environment.sourceUnitRadianceCandelasPerSquareMeter = unitRadiance
            pipeline.environment.ambientRadianceACEScg = [0, 0, 0]
            pipeline.environment.keyRadianceACEScg = [0, 0, 0]
            pipeline.environment.pattern = 0
        }
        if let rotationX = ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_ENVIRONMENT_ROTATION_X_DEGREES"
        ].flatMap(Double.init) {
            pipeline.environment.rotationXDegrees = rotationX
        }
        if let rotationY = ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_ENVIRONMENT_ROTATION_Y_DEGREES"
        ].flatMap(Double.init) {
            pipeline.environment.rotationYDegrees = rotationY
        }
        if let exposureStops = ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_ENVIRONMENT_EXPOSURE_STOPS"
        ].flatMap(Double.init) {
            if pipeline.environment.sourceKind == 1 {
                pipeline.environment.exposureStops = exposureStops
            } else {
                let scale = pow(2, exposureStops)
                pipeline.environment.ambientRadianceACEScg = pipeline.environment
                    .ambientRadianceACEScg.map { $0 * scale }
                pipeline.environment.keyRadianceACEScg = pipeline.environment
                    .keyRadianceACEScg.map { $0 * scale }
            }
        }
        if let keyRadius = ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_ENVIRONMENT_KEY_RADIUS_DEGREES"
        ].flatMap(Double.init) {
            pipeline.environment.keyAngularRadiusDegrees = keyRadius
        }
        let authoredDistance = ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_DISTANCE_METERS"
        ].flatMap(Double.init)
        let orbitX = ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_ORBIT_X_DEGREES"
        ].flatMap(Double.init) ?? 0
        let orbitY = ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_ORBIT_Y_DEGREES"
        ].flatMap(Double.init) ?? 0
        let lookAtTargetWorldX = ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_LOOK_AT_TARGET_WORLD_X_METERS"
        ].flatMap(Double.init) ?? 0
        let lookAtTargetWorldY = ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_LOOK_AT_TARGET_WORLD_Y_METERS"
        ].flatMap(Double.init) ?? 0
        if authoredDistance != nil || orbitX != 0 || orbitY != 0
            || lookAtTargetWorldX != 0 || lookAtTargetWorldY != 0
        {
            let distance = authoredDistance ?? PoseRotationProjection.distance(
                pipeline.cameraPose.position,
                pipeline.screenPose.position
            )
            let lookAtTarget = [
                pipeline.screenPose.position[0] + lookAtTargetWorldX,
                pipeline.screenPose.position[1] + lookAtTargetWorldY,
                pipeline.screenPose.position[2],
            ]
            pipeline.cameraPose.position = PoseRotationProjection.orbitPosition(
                around: lookAtTarget,
                distance: distance,
                rotationDegrees: [orbitX, orbitY, 0]
            )
            pipeline.sceneLens.focusDistanceMeters = distance
            pipeline.cameraLookAt = .init(target: lookAtTarget)
            pipeline.cameraPose.quaternion = PoseRotationProjection.quaternionLooking(
                from: pipeline.cameraPose.position,
                to: lookAtTarget
            )
        }
        switch ProcessInfo.processInfo.environment["SCREEN_MOIRE_CA_MODE"] {
        case "off":
            pipeline.sceneLens.longitudinalChromaticMeters = [0, 0, 0]
            pipeline.sceneLens.lateralChromaticScale = [1, 1, 1]
        case "lateral":
            pipeline.sceneLens.longitudinalChromaticMeters = [0, 0, 0]
        case "longitudinal":
            pipeline.sceneLens.lateralChromaticScale = [1, 1, 1]
        case nil, "full":
            break
        default:
            Issue.record("SCREEN_MOIRE_CA_MODE debe ser off, lateral, longitudinal o full")
            return
        }
        switch ProcessInfo.processInfo.environment["SCREEN_MOIRE_LENS_EVALUATION_MODEL"] {
        case nil, "thin-lens": pipeline.sceneLens.evaluationModel = "thin-lens"
        case "vfx-2d-dof": pipeline.sceneLens.evaluationModel = "vfx-2d-dof"
        default:
            Issue.record(
                "SCREEN_MOIRE_LENS_EVALUATION_MODEL debe ser thin-lens o vfx-2d-dof"
            )
            return
        }
        if let ndStops = ProcessInfo.processInfo.environment["SCREEN_MOIRE_ND_STOPS"]
            .flatMap(Double.init)
        {
            pipeline.shutterMotion.neutralDensityStops = ndStops
        }
        if let shutterSeconds = ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_SHUTTER_SECONDS"
        ].flatMap(Double.init), shutterSeconds > 0 {
            let halfNanoseconds = Int64((shutterSeconds * 0.5 * 1_000_000_000).rounded())
            pipeline.shutterMotion.openOffsetNumerator = -halfNanoseconds
            pipeline.shutterMotion.openOffsetDenominator = 1_000_000_000
            pipeline.shutterMotion.closeOffsetNumerator = halfNanoseconds
            pipeline.shutterMotion.closeOffsetDenominator = 1_000_000_000
        }
        if let exposureIndex = ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_EXPOSURE_INDEX"
        ].flatMap(Double.init), exposureIndex > 0 {
            let analogGain = exposureIndex
                / pipeline.radiometricCalibration.baseExposureIndex
            pipeline.sensor.analogGain = analogGain
            pipeline.develop.middleGrayIlluminanceSeconds /= analogGain
        }
        if let developExposureEV = ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_DEVELOP_EXPOSURE_EV"
        ].flatMap(Double.init) {
            pipeline.develop.exposureEV = developExposureEV
        }
        if let veilingGlare = ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_VEILING_GLARE_FRACTION"
        ].flatMap(Double.init) {
            pipeline.sceneLens.veilingGlareFraction = veilingGlare
        }
        if let focusDistance = ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_FOCUS_DISTANCE_METERS"
        ].flatMap(Double.init) {
            pipeline.sceneLens.focusDistanceMeters = focusDistance
        }
        if let fStop = ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_F_STOP"
        ].flatMap(Double.init) {
            pipeline.sceneLens.fStop = fStop
        }
        if let centerSoftness = ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_CENTER_SOFTNESS_MICROMETERS"
        ].flatMap(Double.init) {
            pipeline.sceneLens.centerSoftnessMicrometers = centerSoftness
        }
        if let edgeSoftness = ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_EDGE_SOFTNESS_MICROMETERS"
        ].flatMap(Double.init) {
            pipeline.sceneLens.edgeSoftnessMicrometers = edgeSoftness
        }
        if let fullWell = ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_FULL_WELL_ELECTRONS"
        ].flatMap(Double.init) {
            pipeline.sensor.fullWellElectrons = fullWell
        }
        if let exposureCount = ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_COMPUTATIONAL_EXPOSURE_COUNT"
        ].flatMap(UInt32.init) {
            pipeline.computationalCapture.exposureCount = exposureCount
        }
        if let bracketSpacing = ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_COMPUTATIONAL_BRACKET_SPACING_STOPS"
        ].flatMap(Double.init) {
            pipeline.computationalCapture.bracketSpacingStops = bracketSpacing
        }
        if let crosstalk = ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_BLOOM_CROSSTALK_FRACTION"
        ].flatMap(Double.init) {
            pipeline.sensor.bloomCrosstalkFraction = crosstalk
        }
        if let overflow = ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_BLOOM_OVERFLOW_FRACTION"
        ].flatMap(Double.init) {
            pipeline.sensor.bloomOverflowTransferFraction = overflow
        }
        switch ProcessInfo.processInfo.environment["SCREEN_MOIRE_GLOBAL_SHUTTER"] {
        case "0": break
        case "1": pipeline.shutterMotion.readoutKind = 0
        default:
            Issue.record("SCREEN_MOIRE_GLOBAL_SHUTTER debe ser 0 o 1")
            return
        }
        let frameContext = try moireFrameContext(
            deviceID: device.id,
            environmentSourcePath: environmentSourcePath
        )
        fixtureImported = .init(
            device: device,
            pipeline: pipeline,
            model: PhysicalModelController().authoringState,
            context: frameContext,
            report: "Headless VFX reference battery"
        )
    }
    let imported: PhysicalSettingsExchange.Imported
    if let settingsPath = processSettings["SCREEN_MOIRE_SETTINGS_DOCUMENT_PATH"] {
        let data = try Data(contentsOf: URL(fileURLWithPath: settingsPath))
        let document = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let decoded = try PhysicalSettingsExchange.decode(from: document)
        var pipeline = decoded.pipeline
        if let evaluationModel = processSettings["SCREEN_MOIRE_FORCE_LENS_EVALUATION_MODEL"] {
            pipeline.sceneLens.evaluationModel = evaluationModel
        }
        if let moireIntensity = processSettings["SCREEN_MOIRE_FORCE_INTENSITY"]
            .flatMap(Double.init)
        {
            pipeline.moireIntensity = moireIntensity
        }
        imported = .init(
            device: decoded.device,
            pipeline: pipeline,
            model: decoded.model,
            context: decoded.context,
            report: decoded.report
        )
    } else {
        imported = fixtureImported
    }
    let resolvedEnvironmentSourcePath = imported.pipeline.environment.sourceKind == 1
        ? environmentSourcePath
        : nil

    let sourcePath = ProcessInfo.processInfo.environment["SCREEN_MOIRE_SOURCE_PATH"]
    let patternID = ProcessInfo.processInfo.environment["SCREEN_MOIRE_PATTERN_ID"]
        .flatMap(UInt32.init)
    if sourcePath != nil && patternID != nil {
        Issue.record("SCREEN_MOIRE_SOURCE_PATH y SCREEN_MOIRE_PATTERN_ID son excluyentes")
        return
    }
    let decoded: DecodedNativeFrame
    if let patternID {
        let pattern = try #require(SyntheticPattern(rawValue: patternID))
        decoded = try pattern.frame()
    } else {
        let sourceURL = sourcePath
            .map(URL.init(fileURLWithPath:))
            ?? moireRepositoryRoot()
                .appendingPathComponent(
                    "apps/screen-desktop/assets/frequency-moire-reference.png"
                )
        decoded = try await NativeMediaDecoder.decode(url: sourceURL, time: .zero)
    }
    let display = try StudioColorMetalDisplay()
    let sourceInputID = try #require(ProcessInfo.processInfo.environment[
        "SCREEN_MOIRE_SOURCE_INPUT_TRANSFORM_ID"
    ])
    let input = try #require(StudioColorInputTransform.catalog.first {
        $0.id == sourceInputID
    })
    let outputSignal = try #require(StudioColorMode.catalog.first {
        $0.id == imported.device.colorModeID
    })
    let source = try display.makeACEScgFrame(
        width: decoded.width,
        height: decoded.height,
        encodedRGBA: decoded.rgba,
        input: input,
        alpha: .ignore
    )
    let checkpoint = try DeviceSignalCheckpoint.prepare(
        sourceACEScg: source,
        inputTransform: input,
        outputSignal: outputSignal,
        alphaInterpretation: "ignore",
        sourceAdjustment: .neutral,
        display: display
    )
    let environmentFrame: EnvironmentRadianceFrame?
    if let environmentSourcePath = resolvedEnvironmentSourcePath {
        let inputID = try #require(ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_ENVIRONMENT_INPUT_TRANSFORM_ID"
        ])
        let environmentInput = try #require(StudioColorInputTransform.catalog.first {
            $0.id == inputID
        })
        let decodedEnvironment = try await NativeMediaDecoder.decode(
            url: URL(fileURLWithPath: environmentSourcePath),
            time: .zero
        )
        let resolved = try display.makeACEScgFrame(
            width: decodedEnvironment.width,
            height: decodedEnvironment.height,
            encodedRGBA: decodedEnvironment.rgba,
            input: environmentInput,
            alpha: .ignore
        )
        environmentFrame = try EnvironmentRadianceFrame.prefiltered(from: resolved)
    } else {
        environmentFrame = nil
    }

    let outputID = try #require(ProcessInfo.processInfo.environment[
        "SCREEN_MOIRE_OUTPUT_TRANSFORM_ID"
    ])
    let output: StudioColorOutputTransform
    if outputID == StudioColorOutputTransform.diagnosticUntoneMappedSRGB.id {
        output = .diagnosticUntoneMappedSRGB
    } else {
        output = try #require(StudioColorOutputTransform.catalog.first {
            $0.id == outputID
        })
    }
    let context = MoireRenderContext(
        source: source,
        deviceSignal: checkpoint.deviceSignal,
        environment: environmentFrame,
        imported: imported,
        display: display,
        output: output
    )
    let baselineIntermediate = try moireBaselineIntermediate()
    let baseline = try await renderMoireVariant(
        name: "baseline",
        context: context,
        identity: 1,
        intermediate: baselineIntermediate
    )
    let skipRepeat = ProcessInfo.processInfo.environment[
        "SCREEN_MOIRE_SKIP_REPEAT"
    ] == "1"
    let repeatedBaseline: MoireVariant? = if skipRepeat {
        nil
    } else {
        try await renderMoireVariant(
            name: "baseline-repeat",
            context: context,
            identity: 1,
            intermediate: baselineIntermediate
        )
    }
    let rendered = baseline.rgba8
    let actualHash = SHA256.hash(data: Data(rendered))
        .map { String(format: "%02x", $0) }
        .joined()
    print("MOIRE_BASELINE expected=\(expectedHash ?? "candidate") actual=\(actualHash)")
    print(
        "MOIRE_TIMING intermediate=\(ProcessInfo.processInfo.environment["SCREEN_MOIRE_BASELINE_INTERMEDIATE"] ?? "missing") "
            + "metalSubmitToResultMs=\(baseline.metalSubmitToResultMilliseconds)"
    )
    if let expectedHash {
        #expect(actualHash == expectedHash)
        let rgba16 = try #require(baseline.rgba16)
        let actualRGBA16Hash = SHA256.hash(data: rgba16.withUnsafeBytes { Data($0) })
            .map { String(format: "%02x", $0) }
            .joined()
        #expect(actualRGBA16Hash == fixture.acceptedOutput?.pixelRGBA16SHA256)
    }
    if let repeatedBaseline {
        #expect(repeatedBaseline.rgba8 == rendered)
    }

    guard let outputDirectory = ProcessInfo.processInfo.environment[
        "SCREEN_MOIRE_DIAGNOSTIC_DIR"
    ] else { return }
    let directory = URL(fileURLWithPath: outputDirectory, isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    try writeMoireVariant(baseline, to: directory)
    try writeMoireResolvedSettings(
        fixture: fixture,
        imported: imported,
        baseline: baseline,
        to: directory
    )
    if ProcessInfo.processInfo.environment["SCREEN_MOIRE_RECORDING_DIAGNOSTIC"] == "1" {
        try writeMoireRecordingDiagnostic(
            cameraRendered: baseline.frame,
            context: context,
            to: directory
        )
    }
    print(
        "MOIRE_VARIANT name=baseline hash=\(baseline.hash) "
            + "meanChroma=\(baseline.meanChroma) p95Chroma=\(baseline.p95Chroma) "
            + "metalSubmitToResultMs=\(baseline.metalSubmitToResultMilliseconds)"
    )

    let apertureOnly = ProcessInfo.processInfo.environment[
        "SCREEN_MOIRE_APERTURE_ONLY"
    ] == "1"
    let psfOnly = ProcessInfo.processInfo.environment[
        "SCREEN_MOIRE_PSF_ONLY"
    ] == "1"
    let variants: [MoireVariant]
    if ProcessInfo.processInfo.environment["SCREEN_MOIRE_ZERO_DOWNSTREAM_ISOLATION"] == "1" {
        let zeroMoire: (inout PhysicalPipelineAuthoringState) throws -> Void = {
            $0.moireIntensity = 0
        }
        variants = try await [
            renderMoireVariant(
                name: "00-device-signal-moire-0",
                context: context,
                identity: 30,
                intermediate: .deviceSignal,
                editPipeline: zeroMoire
            ),
            renderMoireVariant(
                name: "01-panel-emission-moire-0",
                context: context,
                identity: 31,
                intermediate: .panelEmission,
                editPipeline: zeroMoire
            ),
            renderMoireVariant(
                name: "02-subpixel-radiance-moire-0",
                context: context,
                identity: 32,
                intermediate: .subpixelRadiance,
                editPipeline: zeroMoire
            ),
            renderMoireVariant(
                name: "03-panel-uniformity-moire-0",
                context: context,
                identity: 33,
                intermediate: .panelUniformity,
                editPipeline: zeroMoire
            ),
            renderMoireVariant(
                name: "04-panel-light-spread-moire-0",
                context: context,
                identity: 34,
                intermediate: .panelLightSpread,
                editPipeline: zeroMoire
            ),
            renderMoireVariant(
                name: "05-panel-temporal-moire-0",
                context: context,
                identity: 35,
                intermediate: .panelTemporal,
                editPipeline: zeroMoire
            ),
            renderMoireVariant(
                name: "06-relative-geometry-moire-0",
                context: context,
                identity: 36,
                intermediate: .relativeGeometry,
                editPipeline: zeroMoire
            ),
            renderMoireVariant(
                name: "07-cover-environment-moire-0",
                context: context,
                identity: 37,
                intermediate: .coverEnvironment,
                editPipeline: zeroMoire
            ),
            renderMoireVariant(
                name: "08-cover-glow-moire-0",
                context: context,
                identity: 38,
                intermediate: .coverGlow,
                editPipeline: zeroMoire
            ),
            renderMoireVariant(
                name: "09-lens-projection-moire-0",
                context: context,
                identity: 39,
                intermediate: .lensProjection,
                editPipeline: zeroMoire
            ),
            renderMoireVariant(
                name: "10-shutter-motion-moire-0",
                context: context,
                identity: 40,
                intermediate: .shutterMotion,
                editPipeline: zeroMoire
            ),
            renderMoireVariant(
                name: "11-computational-capture-moire-0",
                context: context,
                identity: 41,
                intermediate: .computationalCapture,
                editPipeline: zeroMoire
            ),
            renderMoireVariant(
                name: "12-sensor-collection-moire-0",
                context: context,
                identity: 42,
                intermediate: .sensorCollection,
                editPipeline: zeroMoire
            ),
            renderMoireVariant(
                name: "13-sensor-bloom-moire-0",
                context: context,
                identity: 43,
                intermediate: .sensorBloom,
                editPipeline: zeroMoire
            ),
            renderMoireVariant(
                name: "14-sensor-readout-raw-moire-0",
                context: context,
                identity: 44,
                intermediate: .sensorReadoutRaw,
                editPipeline: zeroMoire
            ),
            renderMoireVariant(
                name: "15-developed-acescg-moire-0",
                context: context,
                identity: 45,
                intermediate: .developedACEScg,
                editPipeline: zeroMoire
            ),
            renderMoireVariant(
                name: "16-camera-rendered-acescg-moire-0",
                context: context,
                identity: 46,
                intermediate: .cameraRenderedACEScg,
                editPipeline: zeroMoire
            ),
        ]
    } else if ProcessInfo.processInfo.environment["SCREEN_MOIRE_PHASE_ISOLATION"] == "1" {
        variants = try await [
            renderMoireVariant(
                name: "before-moire-cover-glow",
                context: context,
                identity: 21,
                intermediate: .coverGlow
            ),
            renderMoireVariant(
                name: "after-moire-intensity-0",
                context: context,
                identity: 22,
                intermediate: .lensProjection,
                editPipeline: { $0.moireIntensity = 0 }
            ),
            renderMoireVariant(
                name: "after-moire-intensity-1",
                context: context,
                identity: 23,
                intermediate: .lensProjection,
                editPipeline: { $0.moireIntensity = 1 }
            ),
        ]
    } else if ProcessInfo.processInfo.environment["SCREEN_MOIRE_BASELINE_ONLY"] == "1" {
        variants = []
    } else if psfOnly {
        variants = try await [
            renderMoireVariant(
                name: "psf-support-2x-proxy",
                context: context,
                identity: 15,
                editPipeline: {
                    let airyRadiusMicrometers = 1.22 * 0.550 * 2
                    $0.sceneLens.centerSoftnessMicrometers =
                        2 * $0.sceneLens.centerSoftnessMicrometers
                        + airyRadiusMicrometers
                    $0.sceneLens.edgeSoftnessMicrometers =
                        2 * $0.sceneLens.edgeSoftnessMicrometers
                        + airyRadiusMicrometers
                }
            ),
        ]
    } else {
        let apertureVariants = try await [
        compensatedApertureVariant(
            name: "f2_8-compensated",
            fStop: 2.8,
            context: context,
            identity: 11
        ),
        compensatedApertureVariant(
            name: "f4-compensated",
            fStop: 4,
            context: context,
            identity: 12
        ),
        compensatedApertureVariant(
            name: "f5_6-compensated",
            fStop: 5.6,
            context: context,
            identity: 13
        ),
        compensatedApertureVariant(
            name: "f8-compensated",
            fStop: 8,
            context: context,
            identity: 14
        ),
        ]
        if apertureOnly {
            variants = apertureVariants
        } else {
            let isolationVariants = try await [
        renderMoireVariant(
            name: "subpixel-0",
            context: context,
            identity: 2,
            editModel: { try $0.setContinuousAmount(
                0,
                stage: .screen(.subpixelGeometry)
            ) }
        ),
        renderMoireVariant(
            name: "spread-0",
            context: context,
            identity: 3,
            editModel: { try $0.setContinuousAmount(
                0,
                stage: .screen(.panelLightSpread)
            ) }
        ),
        renderMoireVariant(
            name: "spread-2",
            context: context,
            identity: 4,
            editModel: { try $0.setContinuousAmount(
                2,
                stage: .screen(.panelLightSpread)
            ) }
        ),
        renderMoireVariant(
            name: "lens-0",
            context: context,
            identity: 5,
            editModel: { try $0.setContinuousAmount(
                0,
                stage: .capture(.lens)
            ) }
        ),
        renderMoireVariant(
            name: "bloom-0",
            context: context,
            identity: 6,
            editModel: { try $0.setContinuousAmount(
                0,
                stage: .capture(.sensorBloom)
            ) }
        ),
        renderMoireVariant(
            name: "noise-0",
            context: context,
            identity: 7,
            editModel: { try $0.setContinuousAmount(
                0,
                stage: .capture(.sensorCollection)
            ) }
        ),
        renderMoireVariant(
            name: "lens-projection",
            context: context,
            identity: 8,
            intermediate: .lensProjection
        ),
        renderMoireVariant(
            name: "shutter-motion",
            context: context,
            identity: 9,
            intermediate: .shutterMotion
        ),
            ]
            variants = isolationVariants + apertureVariants
        }
    }
    for variant in variants {
        try writeMoireVariant(variant, to: directory)
        let difference = meanAbsoluteRGBDifference(
            baseline.rgba8,
            variant.rgba8
        )
        print(
            "MOIRE_VARIANT name=\(variant.name) hash=\(variant.hash) "
                + "meanChroma=\(variant.meanChroma) p95Chroma=\(variant.p95Chroma) "
                + "meanAbsRGBDiffVsBaseline=\(difference) "
                + "metalSubmitToResultMs=\(variant.metalSubmitToResultMilliseconds)"
        )
    }
}

@MainActor
private func moireFrameContext(
    deviceID: String,
    environmentSourcePath: String?
) throws -> PhysicalSettingsExchange.FrameContext {
    let sourceInputTransformID = try #require(
        ProcessInfo.processInfo.environment["SCREEN_MOIRE_SOURCE_INPUT_TRANSFORM_ID"]
    )
    var selection = try RustTestAuthoringCoordinator.defaultSelection(
        inputTransformID: sourceInputTransformID,
        deviceID: deviceID,
        frameRate: .fps24
    )
    let choiceIntents: [(String, String)] = [
        ("placement", "one-to-one"),
        ("color-mode", try #require(ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_COLOR_MODE_ID"
        ])),
        ("cover-glass-preset", try #require(ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_COVER_ID"
        ])),
        ("capture-preset", try #require(ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_CAPTURE_ID"
        ])),
        ("lens-preset", try #require(ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_LENS_ID"
        ])),
        ("lens-evaluation-model", try #require(ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_LENS_EVALUATION_MODEL"
        ])),
        ("device-vfx-alpha-mode", "device-transparency"),
    ]
    for (controlID, optionID) in choiceIntents {
        selection = try RustTestAuthoringCoordinator.apply(
            .setChoice(controlID: controlID, optionID: optionID),
            to: selection
        )
    }
    if environmentSourcePath != nil {
        selection = try RustTestAuthoringCoordinator.apply(
            .setChoice(controlID: "environment-source", optionID: "environment-image"),
            to: selection
        )
    }
    let scalarSettings: [(String, String)] = [
        ("white-luminance", "SCREEN_MOIRE_WHITE_NITS"),
        ("subpixel-geometry-amount", "SCREEN_MOIRE_PANEL_STRUCTURE_AMOUNT"),
        ("panel-uniformity-amount", "SCREEN_MOIRE_PANEL_UNIFORMITY_AMOUNT"),
        ("panel-light-spread-amount", "SCREEN_MOIRE_PANEL_SPREAD_AMOUNT"),
        ("cover-glass-amount", "SCREEN_MOIRE_COVER_CHARACTER_STRENGTH"),
        ("cover-ag-microtexture-amount", "SCREEN_MOIRE_COVER_AG_MICROTEXTURE_CHARACTER_STRENGTH"),
        ("environment-rotation-x-degrees", "SCREEN_MOIRE_ENVIRONMENT_ROTATION_X_DEGREES"),
        ("environment-rotation-y-degrees", "SCREEN_MOIRE_ENVIRONMENT_ROTATION_Y_DEGREES"),
        ("environment-exposure-ev", "SCREEN_MOIRE_ENVIRONMENT_EXPOSURE_STOPS"),
        ("camera-distance-meters", "SCREEN_MOIRE_DISTANCE_METERS"),
        ("camera-orbit-x-degrees", "SCREEN_MOIRE_ORBIT_X_DEGREES"),
        ("camera-orbit-y-degrees", "SCREEN_MOIRE_ORBIT_Y_DEGREES"),
        ("cover-glow-amount", "SCREEN_MOIRE_COVER_GLOW_AMOUNT"),
        ("lens-amount", "SCREEN_MOIRE_LENS_AMOUNT"),
        ("focus-distance-meters", "SCREEN_MOIRE_FOCUS_DISTANCE_METERS"),
        ("f-stop", "SCREEN_MOIRE_F_STOP"),
        ("computational-capture-amount", "SCREEN_MOIRE_COMPUTATIONAL_CHARACTER_STRENGTH"),
        ("computational-exposure-count", "SCREEN_MOIRE_COMPUTATIONAL_EXPOSURE_COUNT"),
        ("computational-bracket-spacing-stops", "SCREEN_MOIRE_COMPUTATIONAL_BRACKET_SPACING_STOPS"),
        ("sensor-noise-amount", "SCREEN_MOIRE_SENSOR_NOISE_AMOUNT"),
    ]
    for (controlID, settingID) in scalarSettings {
        let value = try moireRequiredDouble(settingID)
        selection = try RustTestAuthoringCoordinator.apply(
            .setScalar(controlID: controlID, value: value),
            to: selection
        )
    }

    let environmentResource: PhysicalSettingsExchange.EnvironmentResource
    if let environmentSourcePath {
        guard let environmentInputTransformID = ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_ENVIRONMENT_INPUT_TRANSFORM_ID"
        ] else {
            throw TestAuthoringCoordinatorError.malformedDescriptor(
                "El fixture HDRI no publicó su Input Transform obligatorio."
            )
        }
        let environmentData = try Data(contentsOf: URL(fileURLWithPath: environmentSourcePath))
        let environmentHash = SHA256.hash(data: environmentData)
            .map { String(format: "%02x", $0) }
            .joined()
        environmentResource = .init(
            kind: .image,
            fileName: URL(fileURLWithPath: environmentSourcePath).lastPathComponent,
            sha256: environmentHash,
            inputTransformID: environmentInputTransformID
        )
    } else {
        environmentResource = .init(
            kind: .procedural,
            fileName: nil,
            sha256: nil,
            inputTransformID: nil
        )
    }
    let previewPhaseID = try moirePreviewPhaseID(
        for: #require(ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_BASELINE_INTERMEDIATE"
        ])
    )
    return .init(
        selection: selection,
        sourceInputTransformID: sourceInputTransformID,
        sourceAlphaMode: "Ignorar",
        sourceColorModel: "RGB",
        sourceYUVMatrix: "BT.709",
        sourceSignalRange: "Completo",
        sourcePlacementID: "one-to-one",
        previewOutputTransformID: try #require(ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_OUTPUT_TRANSFORM_ID"
        ]),
        previewPhaseID: previewPhaseID,
        environmentResource: environmentResource,
        referenceResource: .init(
            kind: .none,
            fileName: nil,
            sha256: nil,
            inputTransformID: nil,
            alphaMode: nil,
            signalColorModel: nil,
            signalMatrix: nil,
            signalRange: nil,
            placementID: nil,
            corners: []
        )
    )
}

private func moirePreviewPhaseID(for intermediateID: String) throws -> String {
    try #require([
        "device-signal": "feeder-output",
        "panel-emission": "device-interpretation",
        "subpixel-radiance": "panel-structure",
        "panel-uniformity": "panel-uniformity",
        "panel-light-spread": "panel-light-spread",
        "panel-temporal": "panel-temporal",
        "relative-geometry": "relative-geometry",
        "cover-environment": "cover-environment",
        "cover-glow": "cover-glow",
        "lens-projection": "lens-projection",
        "shutter-motion": "shutter-exposure",
        "camera-rendered-acescg": "camera-rendering-intent",
    ][intermediateID])
}

private func moireBaselineIntermediate() throws -> PhysicalIntermediate {
    guard let authored = ProcessInfo.processInfo.environment[
        "SCREEN_MOIRE_BASELINE_INTERMEDIATE"
    ] else {
        return .developedACEScg
    }
    return try #require([
        "device-signal": PhysicalIntermediate.deviceSignal,
        "panel-emission": .panelEmission,
        "subpixel-radiance": .subpixelRadiance,
        "panel-uniformity": .panelUniformity,
        "panel-light-spread": .panelLightSpread,
        "panel-temporal": .panelTemporal,
        "relative-geometry": .relativeGeometry,
        "cover-environment": .coverEnvironment,
        "cover-glow": .coverGlow,
        "lens-projection": .lensProjection,
        "shutter-motion": .shutterMotion,
        "computational-capture": .computationalCapture,
        "sensor-collection": .sensorCollection,
        "sensor-bloom": .sensorBloom,
        "sensor-readout-raw": .sensorReadoutRaw,
        "developed-acescg": .developedACEScg,
        "camera-rendered-acescg": .cameraRenderedACEScg,
    ][authored])
}

private func moireRequiredDouble(_ key: String) throws -> Double {
    try #require(
        ProcessInfo.processInfo.environment[key].flatMap(Double.init),
        "Falta el número VFX obligatorio \(key)"
    )
}

@MainActor
private func moireResolvedModel(
    from imported: PhysicalSettingsExchange.Imported
) throws -> PhysicalModelController {
    let controller = PhysicalModelController()
    try controller.restoreAuthoringState(imported.model)
    if ProcessInfo.processInfo.environment["SCREEN_MOIRE_SETTINGS_DOCUMENT_PATH"] != nil {
        return controller
    }
    try controller.setContinuousAmount(
        try moireRequiredDouble("SCREEN_MOIRE_COVER_GLOW_AMOUNT"),
        stage: .screen(.coverGlow)
    )
    try controller.setContinuousAmount(
        try moireRequiredDouble("SCREEN_MOIRE_PANEL_SPREAD_AMOUNT"),
        stage: .screen(.panelLightSpread)
    )
    try controller.setContinuousAmount(
        try moireRequiredDouble("SCREEN_MOIRE_PANEL_UNIFORMITY_AMOUNT"),
        stage: .screen(.panelUniformity)
    )
    try controller.setContinuousAmount(
        try moireRequiredDouble("SCREEN_MOIRE_PANEL_STRUCTURE_AMOUNT"),
        stage: .screen(.subpixelGeometry)
    )
    try controller.setContinuousAmount(
        try moireRequiredDouble("SCREEN_MOIRE_SENSOR_NOISE_AMOUNT"),
        stage: .capture(.sensorCollection)
    )
    try controller.setContinuousAmount(
        try moireRequiredDouble("SCREEN_MOIRE_LENS_AMOUNT"),
        stage: .capture(.lens)
    )
    try controller.setContinuousAmount(
        try moireRequiredDouble("SCREEN_MOIRE_COMPUTATIONAL_CHARACTER_STRENGTH"),
        stage: .capture(.computationalCapture)
    )
    return controller
}

@MainActor
private func compensatedApertureVariant(
    name: String,
    fStop: Double,
    context: MoireRenderContext,
    identity: UInt64
) async throws -> MoireVariant {
    let exposureSeconds = (fStop / 2) * (fStop / 2) / 192
    let halfNanoseconds = Int64((exposureSeconds * 0.5 * 1_000_000_000).rounded())
    return try await renderMoireVariant(
        name: name,
        context: context,
        identity: identity,
        editPipeline: {
            $0.sceneLens.fStop = fStop
            $0.shutterMotion.openOffsetNumerator = -halfNanoseconds
            $0.shutterMotion.openOffsetDenominator = 1_000_000_000
            $0.shutterMotion.closeOffsetNumerator = halfNanoseconds
            $0.shutterMotion.closeOffsetDenominator = 1_000_000_000
        }
    )
}

private struct MoireRenderContext {
    let source: StudioColorMetalFrame
    let deviceSignal: StudioColorMetalFrame
    let environment: EnvironmentRadianceFrame?
    let imported: PhysicalSettingsExchange.Imported
    let display: StudioColorMetalDisplay
    let output: StudioColorOutputTransform
}

private struct MoireVariant {
    let name: String
    let width: Int
    let height: Int
    let rgba8: [UInt8]
    let rgba16: [UInt16]?
    let hash: String
    let meanChroma: Double
    let p95Chroma: Double
    let metalSubmitToResultMilliseconds: Double
    let frame: StudioColorMetalFrame
}

@MainActor
private func renderMoireVariant(
    name: String,
    context: MoireRenderContext,
    identity: UInt64,
    intermediate: PhysicalIntermediate = .developedACEScg,
    editPipeline: (inout PhysicalPipelineAuthoringState) throws -> Void = { _ in },
    editModel: (PhysicalModelController) throws -> Void = { _ in }
) async throws -> MoireVariant {
    var pipeline = context.imported.pipeline
    try editPipeline(&pipeline)
    let controller = try moireResolvedModel(from: context.imported)
    try editModel(controller)
    let contributions = controller.orderedContributions
    let uniformity = try #require(contributions.first {
        $0.stage == .screen(.panelUniformity)
    }?.amount)
    let spread = try #require(contributions.first {
        $0.stage == .screen(.panelLightSpread)
    }?.amount)
    var effectiveDevice = context.imported.device
    effectiveDevice.panelUniformity.characterStrength = uniformity
    effectiveDevice.panelLightSpread.characterStrength = spread
    let frame = try PhysicalFrameSelection(
        frameIndex: 0,
        timeNumerator: 0,
        timeDenominator: 24
    )
    let frameIdentity = PhysicalFrameIdentity(high: 0x4D4F4952, low: identity)
    let metalStarted = DispatchTime.now().uptimeNanoseconds
    let requestedDimensions = try PhysicalDimensions(
        width: context.imported.device.nativeWidth,
        height: context.imported.device.nativeHeight
    )
    let job = try PhysicalMetalFrameEngine().submit(
        sourceACEScg: context.source,
        deviceSignal: context.deviceSignal,
        environmentACEScg: context.environment,
        orchestration: try pipeline.orchestration(for: frame),
        resolvedDevice: try effectiveDevice.resolved(),
        resolvedPipeline: try pipeline.resolvedPipeline().resolving(
            contributions: contributions
        ),
        quality: .native,
        deviceVfxAlphaMode: "device-transparency",
        screenAmount: controller.effectiveScreenAmount,
        contributions: contributions,
        requestedDimensions: requestedDimensions,
        renderContext: .fullFrame(requestedDimensions),
        cancellationIdentity: frameIdentity,
        progressIdentity: frameIdentity,
        parameterRevision: identity,
        parameterHash: try PhysicalParameterHash(
            bytes: [UInt8](repeating: UInt8(truncatingIfNeeded: identity), count: 32)
        ),
        rasterPlacement: .oneToOne,
        requestedIntermediate: intermediate
    )
    let snapshot = try await moireTerminalSnapshot(job)
    let metalElapsedNanoseconds = DispatchTime.now().uptimeNanoseconds - metalStarted
    #expect(snapshot.state == .complete)
    var frameResult = try #require(snapshot.frame)
    if ProcessInfo.processInfo.environment["SCREEN_MOIRE_DIAGNOSTIC_IDEAL_FULL_RGB"] == "1" {
        #expect(intermediate == .lensProjection)
        frameResult = try moireIdealFullRGBControl(
            lens: frameResult,
            context: context,
            pipeline: pipeline,
            contributions: contributions
        )
    }
    let rgba8 = try context.display.renderRGBA8(frameResult, output: context.output)
    let rgba16: [UInt16]? = if name != "baseline-repeat" {
        try context.display.renderRGBA16(frameResult, output: context.output)
    } else {
        nil
    }
    let hash = SHA256.hash(data: Data(rgba8))
        .map { String(format: "%02x", $0) }
        .joined()
    var chromaHistogram = [UInt64](repeating: 0, count: 256)
    var chromaSum: UInt64 = 0
    for offset in stride(from: 0, to: rgba8.count, by: 4) {
        let minimum = min(rgba8[offset], rgba8[offset + 1], rgba8[offset + 2])
        let maximum = max(rgba8[offset], rgba8[offset + 1], rgba8[offset + 2])
        let chroma = Int(maximum - minimum)
        chromaHistogram[chroma] += 1
        chromaSum += UInt64(chroma)
    }
    let pixelCount = rgba8.count / 4
    let p95Rank = UInt64(Double(pixelCount) * 0.95)
    var accumulated: UInt64 = 0
    let p95Code = chromaHistogram.indices.first { code in
        accumulated += chromaHistogram[code]
        return accumulated > p95Rank
    } ?? 255
    return MoireVariant(
        name: name,
        width: frameResult.width,
        height: frameResult.height,
        rgba8: rgba8,
        rgba16: rgba16,
        hash: hash,
        meanChroma: Double(chromaSum) / Double(pixelCount) / 255,
        p95Chroma: Double(p95Code) / 255,
        metalSubmitToResultMilliseconds: Double(metalElapsedNanoseconds) / 1_000_000,
        frame: frameResult
    )
}

@MainActor
private func writeMoireRecordingDiagnostic(
    cameraRendered: StudioColorMetalFrame,
    context: MoireRenderContext,
    to directory: URL
) throws {
    let p3Output = try #require(StudioColorOutputTransform.catalog.first {
        $0.id == "aces2-display-p3-sdr-100"
    })
    let cameraP3 = try context.display.renderRGBA16(cameraRendered, output: p3Output)
    let output = try RecordingPhaseExecutor.output(
        cameraRendered: cameraRendered,
        transformID: RecordingPhaseExecutor.iphoneHeicOutputTransformID,
        display: context.display
    )
    let codec = try RecordingPhaseExecutor.codec(
        output: output,
        profileID: RecordingPhaseExecutor.iphoneHeicProfileID,
        character: 1,
        outputTransformID: RecordingPhaseExecutor.iphoneHeicOutputTransformID,
        display: context.display
    )
    let output16 = output.rgba8.map { UInt16($0) * 257 }
    let codec16 = codec.decodedRGBA8.map { UInt16($0) * 257 }
    let metadata = try JSONSerialization.data(withJSONObject: [
        "schema": "ScreenSimulation.RecordingChainDiagnostic",
        "version": 1,
        "recordingOutputTransformID": RecordingPhaseExecutor.iphoneHeicOutputTransformID,
        "recordingProfileID": RecordingPhaseExecutor.iphoneHeicProfileID,
        "quality": RecordingPhaseExecutor.calibratedHeicQuality,
    ], options: [.sortedKeys])
    for (name, rgba) in [
        ("camera-intent-display-p3", cameraP3),
        ("recording-output-display-p3", output16),
        ("recording-codec-display-p3", codec16),
    ] {
        let png = try FrameCheckPNG.encode(
            rgba16: rgba,
            width: cameraRendered.width,
            height: cameraRendered.height,
            colorSpace: CGColorSpace(name: CGColorSpace.displayP3),
            metadata: metadata
        )
        try png.write(to: directory.appendingPathComponent("\(name).png"), options: .atomic)
    }
    try codec.encodedData.write(
        to: directory.appendingPathComponent("recording-codec.heic"), options: .atomic
    )
    let manifest: [String: Any] = [
        "schema": "ScreenSimulation.RecordingChainDiagnostic",
        "version": 1,
        "recordingOutputTransformID": RecordingPhaseExecutor.iphoneHeicOutputTransformID,
        "recordingProfileID": RecordingPhaseExecutor.iphoneHeicProfileID,
        "quality": RecordingPhaseExecutor.calibratedHeicQuality,
        "encodedBytes": codec.encodedBytes,
        "encodedSHA256": codec.encodedSHA256Hex,
        "cameraIntentP3VersusRecordingOutputMaximumCodeDifference": zip(
            cameraP3, output16
        ).map { abs(Int($0) - Int($1)) }.max() ?? 0,
    ]
    try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        .write(to: directory.appendingPathComponent("recording-chain-diagnostic.json"))
}

@MainActor
private func moireIdealFullRGBControl(
    lens: StudioColorMetalFrame,
    context: MoireRenderContext,
    pipeline: PhysicalPipelineAuthoringState,
    contributions: [PhysicalStageContribution]
) throws -> StudioColorMetalFrame {
    let shutterAmount = try #require(contributions.first {
        $0.stage == PhysicalStageID.capture(.exposureShutter)
    }?.amount)
    let open = Double(pipeline.shutterMotion.openOffsetNumerator)
        / Double(pipeline.shutterMotion.openOffsetDenominator)
    let close = Double(pipeline.shutterMotion.closeOffsetNumerator)
        / Double(pipeline.shutterMotion.closeOffsetDenominator)
    let shutterBase = (close - open) * pow(2, -pipeline.shutterMotion.neutralDensityStops)
    let shutterScale = pow(shutterBase, shutterAmount)
    let developScale = 0.18 / pipeline.develop.middleGrayIlluminanceSeconds
        * pow(2, pipeline.develop.exposureEV)
    let scale = Float(
        shutterScale * context.imported.device.whiteLevelNits
            * pipeline.radiometricCalibration.effectiveSensorExposureScale * developScale
    )
    let device = lens.texture.device
    guard let queue = device.makeCommandQueue() else {
        throw StudioColorMetalError.unavailableQueue
    }
    let source = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void ideal_full_rgb(
        texture2d<float, access::read> input [[texture(0)]],
        texture2d<float, access::write> output [[texture(1)]],
        constant float &scale [[buffer(0)]],
        uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
        float2 sourceSize = float2(input.get_width(), input.get_height());
        float2 outputSize = float2(output.get_width(), output.get_height());
        float2 minimum = float2(gid) * sourceSize / outputSize;
        float2 maximum = float2(gid + 1) * sourceSize / outputSize;
        uint2 first = uint2(floor(minimum));
        uint2 last = uint2(ceil(maximum));
        float3 sum = 0.0f;
        float area = 0.0f;
        for (uint y = first.y; y < last.y; ++y) {
            float overlapY = max(0.0f, min(maximum.y, float(y + 1)) - max(minimum.y, float(y)));
            for (uint x = first.x; x < last.x; ++x) {
                float overlapX = max(0.0f, min(maximum.x, float(x + 1)) - max(minimum.x, float(x)));
                float weight = overlapX * overlapY;
                sum += input.read(uint2(min(x, input.get_width() - 1), min(y, input.get_height() - 1))).rgb * weight;
                area += weight;
            }
        }
        output.write(float4(sum / area * scale, 1.0f), gid);
    }
    """
    let library = try device.makeLibrary(source: source, options: nil)
    guard let function = library.makeFunction(name: "ideal_full_rgb") else {
        throw StudioColorMetalError.missingShaderFunction
    }
    let state = try device.makeComputePipelineState(function: function)
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba32Float,
        width: Int(pipeline.sensor.nativeWidth),
        height: Int(pipeline.sensor.nativeHeight),
        mipmapped: false
    )
    descriptor.usage = [.shaderRead, .shaderWrite]
    descriptor.storageMode = .private
    guard let output = device.makeTexture(descriptor: descriptor),
          let command = queue.makeCommandBuffer(),
          let encoder = command.makeComputeCommandEncoder()
    else { throw StudioColorMetalError.textureCreation }
    var authoredScale = scale
    encoder.setComputePipelineState(state)
    encoder.setTexture(lens.texture, index: 0)
    encoder.setTexture(output, index: 1)
    encoder.setBytes(&authoredScale, length: MemoryLayout<Float>.size, index: 0)
    let width = state.threadExecutionWidth
    let height = max(1, state.maxTotalThreadsPerThreadgroup / width)
    encoder.dispatchThreads(
        MTLSize(width: output.width, height: output.height, depth: 1),
        threadsPerThreadgroup: MTLSize(width: width, height: height, depth: 1)
    )
    encoder.endEncoding()
    command.commit()
    command.waitUntilCompleted()
    guard command.status == .completed else { throw StudioColorMetalError.commandFailure }
    return StudioColorMetalFrame(texture: output)
}

private func writeMoireVariant(_ variant: MoireVariant, to directory: URL) throws {
    let rgba16 = try #require(variant.rgba16)
    let rgba16Data = rgba16.withUnsafeBytes { Data($0) }
    let metadata: [String: Any] = [
        "schema": FrameCheckPNG.metadataKeyword,
        "diagnosticVariant": variant.name,
        "metalSubmitToResultMilliseconds": variant.metalSubmitToResultMilliseconds,
        "hashes": [
            "pixelRGBA8SHA256": variant.hash,
            "pixelRGBA16SHA256": SHA256.hash(data: rgba16Data)
                .map { String(format: "%02x", $0) }
                .joined(),
        ],
    ]
    let metadataData = try JSONSerialization.data(
        withJSONObject: metadata,
        options: [.sortedKeys]
    )
    let png = try FrameCheckPNG.encode(
        rgba16: rgba16,
        width: variant.width,
        height: variant.height,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB),
        metadata: metadataData
    )
    try png.write(
        to: directory.appendingPathComponent("moire-\(variant.name).png"),
        options: .atomic
    )
}

@MainActor
private func writeMoireResolvedSettings(
    fixture: VfxReferenceFixture,
    imported: PhysicalSettingsExchange.Imported,
    baseline: MoireVariant,
    to directory: URL
) throws {
    let controller = try moireResolvedModel(from: imported)
    let context = try #require(imported.context)
    let physical = try #require(PhysicalSettingsExchange.metadata(
        device: imported.device,
        pipeline: imported.pipeline,
        model: controller.authoringState,
        context: context
    ))
    let rgba16 = try #require(baseline.rgba16)
    let rgba16Hash = SHA256.hash(data: rgba16.withUnsafeBytes { Data($0) })
        .map { String(format: "%02x", $0) }
        .joined()
    let manifest: [String: Any] = [
        "schema": "ScreenSimulation.VfxResolvedRun",
        "version": 1,
        "fixtureID": fixture.id,
        "fixtureSHA256": fixture.fixtureSHA256,
        "fixtureStatus": fixture.status,
        "fixtureDescription": fixture.description,
        "fixture": fixture.document,
        "resolvedResources": fixture.resolvedResources,
        "resolvedPhysicalSettings": physical,
        "render": [
            "checkpoint": try #require(ProcessInfo.processInfo.environment[
                "SCREEN_MOIRE_BASELINE_INTERMEDIATE"
            ]),
            "width": baseline.width,
            "height": baseline.height,
            "pixelRGBA8SHA256": baseline.hash,
            "pixelRGBA16SHA256": rgba16Hash,
            "metalSubmitToResultMilliseconds": baseline.metalSubmitToResultMilliseconds,
        ],
    ]
    let data = try JSONSerialization.data(
        withJSONObject: manifest,
        options: [.prettyPrinted, .sortedKeys]
    )
    try data.write(
        to: directory.appendingPathComponent("resolved-settings.json"),
        options: .atomic
    )
}

private func meanAbsoluteRGBDifference(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
    guard lhs.count == rhs.count else { return .infinity }
    var sum = 0.0
    var count = 0
    for index in lhs.indices where index % 4 != 3 {
        sum += abs(Double(lhs[index]) - Double(rhs[index])) / 255
        count += 1
    }
    return sum / Double(count)
}

private func moireRepositoryRoot() -> URL {
    var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    for _ in 0..<4 { directory.deleteLastPathComponent() }
    return directory
}

@MainActor
private func moireTerminalSnapshot(
    _ job: PhysicalMetalFrameJob
) async throws -> PhysicalMetalFrameSnapshot {
    for _ in 0..<60_000 {
        let snapshot = try job.snapshot()
        if [.complete, .failed, .cancelled].contains(snapshot.state) {
            return snapshot
        }
        try await Task.sleep(for: .milliseconds(2))
    }
    Issue.record("El diagnóstico headless no alcanzó un estado terminal.")
    return try job.snapshot()
}
