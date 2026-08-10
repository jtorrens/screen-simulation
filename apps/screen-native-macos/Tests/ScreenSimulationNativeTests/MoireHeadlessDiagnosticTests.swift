import CryptoKit
import CoreGraphics
import Foundation
import StudioColor
import Testing
@testable import ScreenSimulationNative

@Test @MainActor func optionalMoireHeadlessDiagnosticIsDeterministic() async throws {
    guard let pngPath = ProcessInfo.processInfo.environment["SCREEN_MOIRE_REFERENCE_PNG"] else {
        return
    }
    let referenceData = try Data(contentsOf: URL(fileURLWithPath: pngPath))
    let metadataData = try #require(FrameCheckPNG.metadata(in: referenceData))
    let document = try #require(
        JSONSerialization.jsonObject(with: metadataData) as? [String: Any]
    )
    let expectedHash = try #require(
        (document["hashes"] as? [String: String])?["pixelRGBA8SHA256"]
    )
    let deviceID = ProcessInfo.processInfo.environment["SCREEN_MOIRE_DEVICE_ID"]
    var imported: PhysicalSettingsExchange.Imported
    if let deviceID {
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
        if let authoredBlackMatrix = ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_BLACK_MATRIX_FRACTION"
        ] {
            let blackMatrix = try #require(Double(authoredBlackMatrix))
            try #require(blackMatrix >= 0 && blackMatrix < 1)
            device.blackMatrixFraction = blackMatrix
        }
        let coverID = ProcessInfo.processInfo.environment["SCREEN_MOIRE_COVER_ID"]
            ?? device.defaultCoverGlassPresetID
        let cover = try #require(try RustCoverGlassCatalog.builtIns().first {
            $0.id == coverID
        })
        var pipeline = try PhysicalPipelineAuthoringState.seeded(
            device: device,
            coverGlass: cover
        )
        if let captureID = ProcessInfo.processInfo.environment["SCREEN_MOIRE_CAPTURE_ID"] {
            let capture = try #require(
                try CapturePresetDefinition.catalog().first { $0.id == captureID }
            )
            let lens = try #require(
                try LensPresetDefinition.catalog().first { $0.id == capture.defaultLensID }
            )
            capture.applyCamera(to: &pipeline, frameRate: 24)
            lens.apply(to: &pipeline)
        }
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
            let environment = try #require(
                try EnvironmentPresetDefinition.catalog().first { $0.id == environmentID }
            )
            environment.apply(to: &pipeline)
        }
        if let rotation = ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_ENVIRONMENT_ROTATION_DEGREES"
        ].flatMap(Double.init) {
            pipeline.environment.rotationDegrees = rotation
        }
        if let exposureStops = ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_ENVIRONMENT_EXPOSURE_STOPS"
        ].flatMap(Double.init) {
            let scale = pow(2, exposureStops)
            pipeline.environment.ambientRadianceACEScg = pipeline.environment
                .ambientRadianceACEScg.map { $0 * scale }
            pipeline.environment.keyRadianceACEScg = pipeline.environment
                .keyRadianceACEScg.map { $0 * scale }
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
        if ProcessInfo.processInfo.environment[
            "SCREEN_MOIRE_GLOBAL_SHUTTER"
        ] == "1" {
            pipeline.shutterMotion.readoutKind = 0
        }
        imported = .init(
            device: device,
            pipeline: pipeline,
            model: PhysicalModelController().authoringState,
            report: "Headless VFX reference battery"
        )
    } else {
        imported = try PhysicalSettingsExchange.decode(from: document)
    }

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
    let input = try #require(StudioColorInputTransform.catalog.first {
        $0.id == "srgb-encoded-rec709"
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
        display: display
    )

    let output = try #require(StudioColorOutputTransform.catalog.first {
        $0.id == "aces2-srgb-sdr-100"
    })
    let context = MoireRenderContext(
        source: source,
        deviceSignal: checkpoint.deviceSignal,
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
    print("MOIRE_BASELINE expected=\(expectedHash) actual=\(actualHash)")
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
    if ProcessInfo.processInfo.environment["SCREEN_MOIRE_BASELINE_ONLY"] == "1" {
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
                stage: .capture(.noise)
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
        "panel-light-spread": .panelLightSpread,
        "relative-geometry": .relativeGeometry,
        "cover-environment": .coverEnvironment,
        "cover-glow": .coverGlow,
        "lens-projection": .lensProjection,
        "shutter-motion": .shutterMotion,
        "sensor-bloom": .sensorBloom,
        "sensor-noise": .sensorNoise,
        "raw-mosaic": .rawMosaic,
        "developed-acescg": .developedACEScg,
    ][authored])
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
    let imported: PhysicalSettingsExchange.Imported
    let display: StudioColorMetalDisplay
    let output: StudioColorOutputTransform
}

private struct MoireVariant {
    let name: String
    let width: Int
    let height: Int
    let rgba8: [UInt8]
    let hash: String
    let meanChroma: Double
    let p95Chroma: Double
    let metalSubmitToResultMilliseconds: Double
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
    let controller = PhysicalModelController()
    try controller.restoreAuthoringState(context.imported.model)
    if let coverGlowAmount = ProcessInfo.processInfo.environment[
        "SCREEN_MOIRE_COVER_GLOW_AMOUNT"
    ].flatMap(Double.init) {
        try controller.setContinuousAmount(
            coverGlowAmount,
            stage: .screen(.coverGlow)
        )
    }
    if let panelSpreadAmount = ProcessInfo.processInfo.environment[
        "SCREEN_MOIRE_PANEL_SPREAD_AMOUNT"
    ].flatMap(Double.init) {
        try controller.setContinuousAmount(
            panelSpreadAmount,
            stage: .screen(.panelLightSpread)
        )
    }
    if let panelStructureAmount = ProcessInfo.processInfo.environment[
        "SCREEN_MOIRE_PANEL_STRUCTURE_AMOUNT"
    ].flatMap(Double.init) {
        try controller.setContinuousAmount(
            panelStructureAmount,
            stage: .screen(.subpixelGeometry)
        )
    }
    if let sensorNoiseAmount = ProcessInfo.processInfo.environment[
        "SCREEN_MOIRE_SENSOR_NOISE_AMOUNT"
    ].flatMap(Double.init) {
        try controller.setContinuousAmount(
            sensorNoiseAmount,
            stage: .capture(.noise)
        )
    }
    if let lensAmount = ProcessInfo.processInfo.environment[
        "SCREEN_MOIRE_LENS_AMOUNT"
    ].flatMap(Double.init) {
        try controller.setContinuousAmount(
            lensAmount,
            stage: .capture(.lens)
        )
    }
    try editModel(controller)
    let contributions = controller.orderedContributions
    let spread = try #require(contributions.first {
        $0.stage == .screen(.panelLightSpread)
    }?.amount)
    var effectiveDevice = context.imported.device
    effectiveDevice.panelLightSpread.characterStrength = spread
    let frame = try PhysicalFrameSelection(
        frameIndex: 0,
        timeNumerator: 0,
        timeDenominator: 24
    )
    let frameIdentity = PhysicalFrameIdentity(high: 0x4D4F4952, low: identity)
    let metalStarted = DispatchTime.now().uptimeNanoseconds
    let job = try PhysicalMetalFrameEngine().submit(
        sourceACEScg: context.source,
        deviceSignal: context.deviceSignal,
        orchestration: try pipeline.orchestration(for: frame),
        resolvedDevice: try effectiveDevice.resolved(),
        resolvedPipeline: try pipeline.resolvedPipeline().resolving(
            contributions: contributions
        ),
        quality: .native,
        screenAmount: controller.effectiveScreenAmount,
        contributions: contributions,
        requestedDimensions: try PhysicalDimensions(
            width: context.imported.device.nativeWidth,
            height: context.imported.device.nativeHeight
        ),
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
    let frameResult = try #require(snapshot.frame)
    let rgba8 = try context.display.renderRGBA8(frameResult, output: context.output)
    let hash = SHA256.hash(data: Data(rgba8))
        .map { String(format: "%02x", $0) }
        .joined()
    var chroma: [Double] = []
    chroma.reserveCapacity(rgba8.count / 4)
    for offset in stride(from: 0, to: rgba8.count, by: 4) {
        let minimum = min(rgba8[offset], rgba8[offset + 1], rgba8[offset + 2])
        let maximum = max(rgba8[offset], rgba8[offset + 1], rgba8[offset + 2])
        chroma.append(Double(maximum - minimum) / 255)
    }
    chroma.sort()
    return MoireVariant(
        name: name,
        width: frameResult.width,
        height: frameResult.height,
        rgba8: rgba8,
        hash: hash,
        meanChroma: chroma.reduce(0, +) / Double(chroma.count),
        p95Chroma: chroma[min(chroma.count - 1, Int(Double(chroma.count) * 0.95))],
        metalSubmitToResultMilliseconds: Double(metalElapsedNanoseconds) / 1_000_000
    )
}

private func writeMoireVariant(_ variant: MoireVariant, to directory: URL) throws {
    let metadata: [String: Any] = [
        "schema": FrameCheckPNG.metadataKeyword,
        "diagnosticVariant": variant.name,
        "metalSubmitToResultMilliseconds": variant.metalSubmitToResultMilliseconds,
        "hashes": ["pixelRGBA8SHA256": variant.hash],
    ]
    let metadataData = try JSONSerialization.data(
        withJSONObject: metadata,
        options: [.sortedKeys]
    )
    let png = try FrameCheckPNG.encode(
        rgba8: variant.rgba8,
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
