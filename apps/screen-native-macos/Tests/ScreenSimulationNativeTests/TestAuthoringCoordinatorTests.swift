import Metal
import ScreenSimulationPresentation
import StudioMedia
import Testing
@testable import ScreenSimulationNative

@MainActor
private func requestPhysicalPreview(_ qualityID: String, in workspace: WorkspaceModel) throws {
    let presentation = try #require(workspace.testPresentation)
    guard case let .choice(quality) = try #require(presentation.previewControls.first) else {
        Issue.record("Calidad debe ser una selección.")
        return
    }
    workspace.handleTestIntent(.setChoice(controlID: quality.id, optionID: qualityID))
}

private func canonicalTestSelection() -> TestAuthoringResolvedSelection {
    .init(
        inputTransformID: "srgb-encoded-rec709",
        outputSignalID: "srgb",
        deviceID: "lcd-asus-proart-pa329cv",
        colorModeID: "srgb",
        deviceEOTFGamma: 2.2,
        whiteLuminanceNits: 350,
        placementID: "fit",
        previewQualityID: "draft",
        frameRate: .fps24,
        sourceExposureEV: 0,
        sourceContrast: 1,
        sourceSaturation: 1,
        sourceTemperatureKelvin: 6500,
        sourceTint: 0,
        subpixelGeometryAmount: 1,
        panelUniformityAmount: 1,
        panelLightSpreadAmount: 1,
        capturePresetID: "iphone-16e-main-48mp",
        captureRasterModeID: "half",
        lensEvaluationModelID: "vfx-2d-dof",
        geometryModeID: "look-at",
        cameraDistanceMeters: 0.15,
        cameraOrbitXDegrees: 0,
        cameraOrbitYDegrees: -5,
        cameraPositionXMeters: -0.013_073_361,
        cameraPositionYMeters: 0,
        cameraPositionZMeters: 0.149_429_2,
        cameraRotationXDegrees: 0,
        cameraRotationYDegrees: -5,
        cameraRotationZDegrees: 0,
        screenPositionXMeters: 0,
        screenPositionYMeters: 0,
        screenPositionZMeters: 0,
        screenRotationXDegrees: 0,
        screenYawDegrees: 0,
        screenRotationZDegrees: 0,
        coverGlassPresetID: "cover-matte-ar",
        coverGlassAmount: 1,
        coverAgMicrotextureAmount: 1,
        environmentSourceID: "environment-none",
        environmentAmount: 0,
        environmentRotationXDegrees: 0,
        environmentRotationYDegrees: 0,
        environmentExposureEV: 0,
        environmentContrast: 1,
        environmentSaturation: 1,
        environmentTemperatureKelvin: 6500,
        environmentTint: 0,
        environmentProjectionID: "distant",
        environmentSphereRadiusMeters: 5,
        coverGlowAmount: 1,
        lensPresetID: "iphone-16e-main-integrated",
        focalLengthMillimeters: 4.2,
        lensAmount: 1,
        autofocusEnabled: true,
        focusDistanceMeters: 0.15,
        fStop: 1.64,
        exposureTimeSeconds: 1.0 / 288.0,
        shutterMotionAmount: 1,
        computationalCharacterStrength: 1,
        computationalExposureCount: 3,
        computationalBracketSpacingStops: 1,
        sensorBloomAmount: 1,
        sensorBloomCrosstalkFraction: 0.020,
        sensorBloomOverflowTransferFraction: 0.30,
        sensorNoiseAmount: 1,
        cameraLookExposureEV: 0.5,
        cameraLookContrast: 1.10,
        cameraLookSaturation: 1.25,
        cameraLookTemperatureKelvin: 6_500,
        cameraLookTint: 0,
        deliveryPresetID: "uhd",
        deliveryWidth: 3_840,
        deliveryHeight: 2_160,
        deliveryPlacementID: "fit",
        deliveryBackgroundID: "black",
        recordingOutputTransformID: "iphone-heic-display-p3-srgb-full-v2",
        recordingProfileID: "iphone-heic-photo-v1",
        recordingCharacter: 1
    )
}

@Test func testAuthoringBridgePreservesFractionalFrameRate() throws {
    let rate = try ExactFrameRate(numerator: 24_000, denominator: 1_001)
    let selection = try RustTestAuthoringCoordinator.defaultSelection(
        inputTransformID: "srgb-encoded-rec709",
        deviceID: "lcd-asus-proart-pa329cv",
        frameRate: rate
    )
    #expect(selection.frameRate == rate)
}

@Test func exactFrameRateDecodingRejectsZeroDenominator() throws {
    let bytes = Data(#"{"numerator":24000,"denominator":0}"#.utf8)
    #expect(throws: StudioMediaContractError.self) {
        try JSONDecoder().decode(ExactFrameRate.self, from: bytes)
    }
}

@Test func nativeRenderButtonFollowsTheAuthoritativePhysicalFrameState() {
    #expect(NativeRenderButtonState.resolve(
        frameState: .complete,
        progress: 1,
        hasActiveTask: false,
        cancellationRequested: false
    ) == .complete)
    #expect(NativeRenderButtonState.resolve(
        frameState: .rendering,
        progress: 0.42,
        hasActiveTask: true,
        cancellationRequested: false
    ) == .rendering(progress: 0.42))
    #expect(NativeRenderButtonState.resolve(
        frameState: .rendering,
        progress: 1,
        hasActiveTask: true,
        cancellationRequested: false
    ) == .rendering(progress: 0.99))
    #expect(NativeRenderButtonState.resolve(
        frameState: .rendering,
        progress: 0.42,
        hasActiveTask: true,
        cancellationRequested: true
    ) == .cancelling)
    #expect(NativeRenderButtonState.resolve(
        frameState: .stale,
        progress: 0,
        hasActiveTask: false,
        cancellationRequested: false
    ) == .outdated)
}

@Test func rustPublishesTheCompleteOrderedTestPipeline() throws {
    let snapshot = try RustTestAuthoringCoordinator.snapshot(
        selection: canonicalTestSelection(),
        selectedPreviewPhaseID: nil
    )

    #expect(snapshot.presentation.phases.map(\.label) == [
        "Origen", "Ajuste de fuente", "Salida del feeder", "Mapeo e interpretación del dispositivo",
        "Trama del panel", "Uniformidad del panel", "Dispersión de luz del panel",
        "Geometría relativa",
        "Cristal y entorno", "Resplandor del cristal", "Objetivo y proyección",
        "Exposición y obturador", "Captura computacional",
        "Colección del fotosito, CFA y ruido", "Crosstalk y bloom del sensor",
        "Lectura del sensor y RAW", "Revelado y demosaico",
        "Intención de render de cámara", "Raster de entrega", "Señal de grabación · diagnóstico",
        "Códec de grabación",
    ])
    #expect(snapshot.presentation.selectedPhaseID == snapshot.presentation.phases.last?.id)
    for index in 0..<(snapshot.presentation.phases.count - 1) {
        #expect(snapshot.presentation.phases[index].outputArtifactID
            == snapshot.presentation.phases[index + 1].inputArtifactID)
    }
    #expect(snapshot.previewResultByPhaseID[snapshot.presentation.phases[0].id]
        == .sourceACEScg)
    #expect(snapshot.previewResultByPhaseID[snapshot.presentation.phases[1].id]
        == .sourceAdjustment)
    #expect(snapshot.previewResultByPhaseID[snapshot.presentation.phases[2].id]
        == .feederSignal)
    #expect(snapshot.previewResultByPhaseID[snapshot.presentation.phases[3].id]
        == .deviceInterpretation)
    #expect(snapshot.previewResultByPhaseID[snapshot.presentation.phases[4].id]
        == .panelStructure)
    #expect(snapshot.previewResultByPhaseID[snapshot.presentation.phases[5].id]
        == .panelUniformity)
    #expect(snapshot.previewResultByPhaseID[snapshot.presentation.phases[6].id]
        == .panelLightSpread)
    #expect(snapshot.previewResultByPhaseID[snapshot.presentation.phases[7].id]
        == .relativeGeometry)
    #expect(snapshot.previewResultByPhaseID[snapshot.presentation.phases[8].id]
        == .coverEnvironment)
    #expect(snapshot.previewResultByPhaseID[snapshot.presentation.phases[9].id]
        == .coverGlow)
    #expect(snapshot.previewResultByPhaseID[snapshot.presentation.phases[10].id]
        == .lensProjection)
    #expect(snapshot.previewResultByPhaseID[snapshot.presentation.phases[11].id]
        == .shutterExposure)
    #expect(snapshot.previewResultByPhaseID[snapshot.presentation.phases[12].id]
        == .computationalCapture)
    #expect(snapshot.previewResultByPhaseID[snapshot.presentation.phases[13].id]
        == .sensorCollection)
    #expect(snapshot.previewResultByPhaseID[snapshot.presentation.phases[14].id]
        == .sensorBloom)
    #expect(snapshot.previewResultByPhaseID[snapshot.presentation.phases[15].id]
        == .sensorReadoutRaw)
    #expect(snapshot.previewResultByPhaseID[snapshot.presentation.phases[16].id]
        == .developDemosaic)
    #expect(snapshot.physicalIntermediateByPhaseID[snapshot.presentation.phases[0].id] == nil)
    #expect(snapshot.physicalIntermediateByPhaseID[snapshot.presentation.phases[1].id] == nil)
    #expect(snapshot.physicalIntermediateByPhaseID[snapshot.presentation.phases[2].id]
        == .deviceSignal)
    #expect(snapshot.physicalIntermediateByPhaseID[snapshot.presentation.phases[14].id]
        == .sensorBloom)
    #expect(snapshot.physicalIntermediateByPhaseID[snapshot.presentation.phases[15].id]
        == .sensorReadoutRaw)
    #expect(snapshot.physicalIntermediateByPhaseID[snapshot.presentation.phases[16].id]
        == .developedACEScg)
    for index in 17..<snapshot.presentation.phases.count {
        #expect(snapshot.physicalIntermediateByPhaseID[snapshot.presentation.phases[index].id]
            == .cameraRenderedACEScg)
    }

    let controls = snapshot.presentation.phases[2].sections.flatMap(\.controls)
    #expect(controls.count == 2)
    guard case let .choice(outputSignal) = controls[0] else {
        Issue.record("Output Signal debe llegar como opción publicada por Rust.")
        return
    }
    #expect(outputSignal.selectedID == "srgb")
    #expect(outputSignal.options.map(\.id) == [
        "srgb", "rec709-gamma22", "rec709-gamma24",
        "rec2100-pq-1000", "rec2100-hlg-1000",
    ])
    let deviceControls = snapshot.presentation.phases[3].sections.flatMap(\.controls)
    guard case let .choice(colorMode) = deviceControls[1] else {
        Issue.record("Color Mode debe pertenecer a la fase del dispositivo.")
        return
    }
    #expect(colorMode.options.map(\.id) == ["srgb", "rec709-gamma24"])
    #expect(snapshot.presentation.previewControls.count == 1)
    #expect(snapshot.presentation.phases.allSatisfy { !$0.effectSummary.isEmpty })
    #expect(snapshot.presentation.phases[4].headerControlID == "subpixel-geometry-amount")
    guard case let .scalar(subpixel) = snapshot.presentation.phases[4].sections
        .flatMap(\.controls).first
    else {
        Issue.record("La trama debe ser un escalar publicado por Rust.")
        return
    }
    #expect(subpixel.value == 1)
    #expect(subpixel.minimum == 0)
    #expect(subpixel.maximum == 4)
    #expect(snapshot.presentation.phases[5].headerControlID == "panel-uniformity-amount")
    guard case let .scalar(uniformity) = snapshot.presentation.phases[5].sections
        .flatMap(\.controls).first
    else {
        Issue.record("La uniformidad debe ser un escalar publicado por Rust.")
        return
    }
    #expect(uniformity.value == 1)
    #expect(uniformity.minimum == 0)
    #expect(uniformity.maximum == 4)
    let bloomControls = snapshot.presentation.phases[14].sections.flatMap(\.controls)
    #expect(bloomControls.map(\.id) == [
        "sensor-bloom-amount",
        "sensor-bloom-crosstalk-fraction",
        "sensor-bloom-overflow-transfer-fraction",
    ])
}

@Test @MainActor func editingAFeederControlRevealsItsCumulativePreview() async throws {
    let workspace = WorkspaceModel()
    let asus = try #require(try RustDeviceCatalog.builtIns().first {
        $0.name.contains("ASUS ProArt")
    })
    let cover = try #require(try RustCoverGlassCatalog.builtIns().first {
        $0.id == asus.defaultCoverGlassPresetID
    })
    workspace.selectDevice(asus, coverGlass: cover, amount: 0)
    workspace.setTestPageActive(true)
    let presentation = try #require(workspace.testPresentation)
    workspace.handleTestIntent(.selectPhase(presentation.phases[0].id))
    let feederPhase = presentation.phases[2]
    guard case let .choice(outputSignal) = feederPhase.sections.flatMap(\.controls).first else {
        Issue.record("Output Signal debe ser una selección.")
        return
    }

    workspace.handleTestIntent(.setChoice(
        controlID: outputSignal.id,
        optionID: "rec709-gamma24"
    ))
    try requestPhysicalPreview("draft", in: workspace)
    for _ in 0..<2_000 {
        if workspace.deviceSignalCheckpoint?.metadata.outputSignalID == "rec709-gamma24" {
            break
        }
        try await Task.sleep(for: .milliseconds(2))
    }

    #expect(workspace.testPresentation?.selectedPhaseID == feederPhase.id)
    #expect(workspace.deviceSignalCheckpoint?.metadata.outputSignalID == "rec709-gamma24")
}

@Test @MainActor func deviceInterpretationStopsBeforeTheEnabledSensor() async throws {
    let workspace = WorkspaceModel()
    workspace.choosePattern(.frequencyMoireReference, undoManager: nil)
    let asus = try #require(try RustDeviceCatalog.builtIns().first {
        $0.name.contains("ASUS ProArt")
    })
    let cover = try #require(try RustCoverGlassCatalog.builtIns().first {
        $0.id == asus.defaultCoverGlassPresetID
    })
    workspace.selectDevice(asus, coverGlass: cover, amount: 0)
    workspace.setTestPageActive(true)
    let presentation = try #require(workspace.testPresentation)
    workspace.handleTestIntent(.selectPhase(presentation.phases[3].id))
    try requestPhysicalPreview("draft", in: workspace)
    for _ in 0..<2_000 {
        if workspace.deviceSignalCheckpoint != nil,
           workspace.physicalPublicationSummary.contains("Device"),
           workspace.physicalPublicationSummary.contains("publicado") { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(workspace.physicalPublicationSummary.contains("publicado"))
    let checkpoint = try #require(workspace.deviceSignalCheckpoint)
    let feeder = try workspace.metalDisplay.readLinearRGBA(checkpoint.deviceSignal)
    let feederMeans = (0..<3).map { channel in
        stride(from: channel, to: feeder.count, by: 4).reduce(Float.zero) {
            $0 + max(0, feeder[$1])
        } / Float(checkpoint.deviceSignal.width * checkpoint.deviceSignal.height)
    }
    #expect(feederMeans.allSatisfy { $0 > 0.1 })
    let texture = try #require(workspace.metalFrame?.texture)
    #expect(texture.pixelFormat == .rgba32Float)
    var values = [Float](repeating: 0, count: texture.width * texture.height * 4)
    texture.getBytes(
        &values,
        bytesPerRow: texture.width * 4 * MemoryLayout<Float>.size,
        from: MTLRegionMake2D(0, 0, texture.width, texture.height),
        mipmapLevel: 0
    )
    let rgb = values.enumerated().compactMap { index, value in
        index % 4 == 3 ? nil : value
    }
    let channelMeans = (0..<3).map { channel in
        stride(from: channel, to: values.count, by: 4).reduce(Float.zero) {
            $0 + max(0, values[$1])
        } / Float(texture.width * texture.height)
    }
    #expect(rgb.allSatisfy { $0.isFinite })
    #expect(channelMeans.allSatisfy { $0 > 0 })
    let weakest = try #require(channelMeans.min())
    let strongest = try #require(channelMeans.max())
    #expect(strongest / weakest < 2)
}

@Test @MainActor func panelStructurePublishesSubpixelRadianceWithoutRunningLaterStages() async throws {
    let workspace = WorkspaceModel()
    workspace.choosePattern(.frequencyMoireReference, undoManager: nil)
    let asus = try #require(try RustDeviceCatalog.builtIns().first {
        $0.name.contains("ASUS ProArt")
    })
    let cover = try #require(try RustCoverGlassCatalog.builtIns().first {
        $0.id == asus.defaultCoverGlassPresetID
    })
    workspace.selectDevice(asus, coverGlass: cover, amount: 0)
    workspace.setTestPageActive(true)
    let presentation = try #require(workspace.testPresentation)
    workspace.handleTestIntent(.selectPhase(presentation.phases[4].id))
    try requestPhysicalPreview("draft", in: workspace)
    for _ in 0..<2_000 {
        if workspace.physicalPublicationSummary.contains("Subpixel") { break }
        try await Task.sleep(for: .milliseconds(2))
    }

    #expect(workspace.physicalPublicationSummary.contains("Subpixel"))
    #expect(!workspace.physicalPublicationSummary.contains("Sensor"))
    #expect((workspace.metalFrame?.width ?? 0) > 0)
    #expect((workspace.metalFrame?.height ?? 0) > 0)
}

@Test @MainActor func lensProjectionUsesTheTestAuthoredCameraInsteadOfTheFlatCheckpoint() async throws {
    let workspace = WorkspaceModel()
    workspace.choosePattern(.frequencyMoireReference, undoManager: nil)
    let asus = try #require(try RustDeviceCatalog.builtIns().first {
        $0.name.contains("ASUS ProArt")
    })
    let cover = try #require(try RustCoverGlassCatalog.builtIns().first {
        $0.id == asus.defaultCoverGlassPresetID
    })
    workspace.selectDevice(asus, coverGlass: cover, amount: 0)
    workspace.setTestPageActive(true)
    var presentation = try #require(workspace.testPresentation)
    let qualityControl = try #require(presentation.previewControls.first)
    guard case let .choice(quality) = qualityControl else {
        Issue.record("Calidad debe ser una selección.")
        return
    }
    workspace.handleTestIntent(.setChoice(controlID: quality.id, optionID: "draft"))
    presentation = try #require(workspace.testPresentation)

    let beforeFlat = workspace.metalFrame?.texture
    workspace.handleTestIntent(.selectPhase(presentation.phases[6].id))
    for _ in 0..<2_000 {
        if workspace.requestedPhysicalIntermediate == .panelLightSpread,
           workspace.metalFrame?.texture !== beforeFlat,
           workspace.physicalPublicationSummary.contains("Panel Light Spread"),
           workspace.physicalPublicationSummary.contains("publicado") { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    let flatFrame = try #require(workspace.metalFrame)
    let flat = try workspace.metalDisplay.readLinearRGBA(flatFrame)

    workspace.handleTestIntent(.selectPhase(presentation.phases[10].id))
    for _ in 0..<2_000 {
        if workspace.requestedPhysicalIntermediate == .lensProjection,
           workspace.metalFrame?.texture !== flatFrame.texture,
           workspace.physicalPublicationSummary.contains("Lens/Projection"),
           workspace.physicalPublicationSummary.contains("publicado") { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    let projectedFrame = try #require(workspace.metalFrame)
    let projected = try workspace.metalDisplay.readLinearRGBA(projectedFrame)

    workspace.changePhysicalStageAmount(0, stage: .capture(.geometry))
    try requestPhysicalPreview("draft", in: workspace)
    for _ in 0..<2_000 {
        if let replacement = workspace.metalFrame,
           replacement.texture !== projectedFrame.texture,
           workspace.physicalPublicationSummary.contains("Lens/Projection"),
           workspace.physicalPublicationSummary.contains("publicado") { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    let geometryDisabledFrame = try #require(workspace.metalFrame)
    let geometryDisabled = try workspace.metalDisplay.readLinearRGBA(geometryDisabledFrame)

    #expect(projectedFrame.width == flatFrame.width)
    #expect(projectedFrame.height == flatFrame.height)
    let meanAbsoluteDifference = zip(projected, flat).reduce(Float.zero) {
        $0 + abs($1.0 - $1.1)
    } / Float(projected.count)
    #expect(meanAbsoluteDifference.isFinite)
    let geometryDifference = zip(projected, geometryDisabled).reduce(Float.zero) {
        $0 + abs($1.0 - $1.1)
    } / Float(projected.count)
    #expect(geometryDifference > 0.001)
}

@Test func deviceIntentReturnsOneAtomicResolvedSelection() throws {
    let current = canonicalTestSelection()
    let snapshot = try RustTestAuthoringCoordinator.snapshot(
        selection: current,
        selectedPreviewPhaseID: nil
    )
    let deviceControl = snapshot.presentation.phases[3].sections
        .flatMap(\.controls).first
    guard case let .choice(device) = deviceControl else {
        Issue.record("Device debe ser un selector publicado por Rust.")
        return
    }
    let tv = try #require(device.options.first { $0.label.contains("32 HD") })
    let resolved = try RustTestAuthoringCoordinator.apply(
        .setChoice(controlID: device.id, optionID: tv.id),
        to: current
    )
    #expect(resolved.deviceID == tv.id)
    #expect(resolved.outputSignalID == "srgb")
    #expect(resolved.colorModeID == "rec709-gamma24")
    #expect(resolved.whiteLuminanceNits == 250)
    #expect(resolved.coverAgMicrotextureAmount == 1)
}

@Test func coverMicrotextureControlIsVisibleAndResetsToTheSelectedPreset() throws {
    let current = canonicalTestSelection()
    let snapshot = try RustTestAuthoringCoordinator.snapshot(
        selection: current,
        selectedPreviewPhaseID: nil
    )
    let controls = snapshot.presentation.phases[8].sections.flatMap(\.controls)
    guard case let .scalar(control) = controls.first(where: {
        $0.id == "cover-ag-microtexture-amount"
    }) else {
        Issue.record("Rust debe publicar la microtextura AG como control escalar visible.")
        return
    }
    #expect(control.minimum == 0)
    #expect(control.maximum == 4)
    #expect(control.resetValue == 1)
    let edited = try RustTestAuthoringCoordinator.apply(
        .setScalar(controlID: control.id, value: 2.5),
        to: current
    )
    #expect(edited.coverAgMicrotextureAmount == 2.5)
}

@Test func externalEnvironmentSelectionPublishesIndependentXYRotationAndExposure() throws {
    let current = canonicalTestSelection()
    let selected = try RustTestAuthoringCoordinator.apply(
        .setChoice(controlID: "environment-source", optionID: "environment-image"),
        to: current
    )
    let rotatedX = try RustTestAuthoringCoordinator.apply(
        .setScalar(controlID: "environment-rotation-x-degrees", value: -25),
        to: selected
    )
    let rotatedY = try RustTestAuthoringCoordinator.apply(
        .setScalar(controlID: "environment-rotation-y-degrees", value: -57.3),
        to: rotatedX
    )
    let exposed = try RustTestAuthoringCoordinator.apply(
        .setScalar(controlID: "environment-exposure-ev", value: -1),
        to: rotatedY
    )

    #expect(exposed.environmentSourceID == "environment-image")
    #expect(exposed.environmentRotationXDegrees == -25)
    #expect(abs(exposed.environmentRotationYDegrees + 57.3) < 0.0001)
    #expect(exposed.environmentExposureEV == -1)
}

@Test @MainActor func everyTestPhaseSelectsItsOwnCumulativePreviewRoute() throws {
    let workspace = WorkspaceModel()
    workspace.choosePattern(.frequencyMoireReference, undoManager: nil)
    let asus = try #require(try RustDeviceCatalog.builtIns().first {
        $0.name.contains("ASUS ProArt")
    })
    let cover = try #require(try RustCoverGlassCatalog.builtIns().first {
        $0.id == asus.defaultCoverGlassPresetID
    })
    workspace.selectDevice(asus, coverGlass: cover, amount: 0)
    workspace.setTestPageActive(true)
    let presentation = try #require(workspace.testPresentation)
    let expected: [PhysicalIntermediate] = [
        .sourceACEScg,
        .sourceACEScg,
        .deviceSignal,
        .panelEmission,
        .subpixelRadiance,
        .panelUniformity,
        .panelLightSpread,
        .relativeGeometry,
        .coverEnvironment,
        .coverGlow,
        .lensProjection,
        .shutterMotion,
        .computationalCapture,
        .sensorCollection,
        .sensorBloom,
        .sensorReadoutRaw,
        .developedACEScg,
        .cameraRenderedACEScg,
        .cameraRenderedACEScg,
        .cameraRenderedACEScg,
        .cameraRenderedACEScg,
    ]
    #expect(presentation.phases.count == expected.count)
    for (phase, intermediate) in zip(presentation.phases, expected) {
        workspace.handleTestIntent(.selectPhase(phase.id))
        #expect(workspace.testPresentation?.selectedPhaseID == phase.id)
        #expect(workspace.requestedPhysicalIntermediate == intermediate)
    }
}

@Test @MainActor func cumulativePreviewMaterializesThePlacedFeederSignal() async throws {
    let workspace = WorkspaceModel()
    let asus = try #require(try RustDeviceCatalog.builtIns().first {
        $0.name.contains("ASUS ProArt")
    })
    let cover = try #require(try RustCoverGlassCatalog.builtIns().first {
        $0.id == asus.defaultCoverGlassPresetID
    })
    workspace.selectDevice(asus, coverGlass: cover, amount: 0)
    workspace.setTestPageActive(true)

    let presentation = try #require(workspace.testPresentation)
    let feederPhase = try #require(presentation.phases.first {
        $0.outputArtifactID == "placed-feeder-signal-v1"
    })
    workspace.handleTestIntent(.selectPhase(feederPhase.id))
    try requestPhysicalPreview("draft", in: workspace)
    for _ in 0..<2_000 {
        if workspace.deviceSignalCheckpoint?.metadata.outputSignalID == "srgb",
           workspace.physicalPublicationSummary.contains("publicado") { break }
        try await Task.sleep(for: .milliseconds(2))
    }

    #expect(workspace.testPresentation?.selectedPhaseID == feederPhase.id)
    #expect(workspace.deviceSignalCheckpoint?.metadata.outputSignalID == "srgb")
    #expect(workspace.physicalPublicationSummary.contains("publicado"))
    let frame = try #require(workspace.metalFrame)
    let device = try #require(workspace.modelDeviceDefinition)
    #expect(abs(
        Double(frame.width) / Double(frame.height)
            - Double(device.nativeWidth) / Double(device.nativeHeight)
    ) < 0.001)
}

@Test @MainActor func deviceColorModeChangesInterpretationWithoutRecodingTheFeeder() throws {
    let workspace = WorkspaceModel()
    let asus = try #require(try RustDeviceCatalog.builtIns().first {
        $0.name.contains("ASUS ProArt")
    })
    let cover = try #require(try RustCoverGlassCatalog.builtIns().first {
        $0.id == asus.defaultCoverGlassPresetID
    })
    workspace.selectDevice(asus, coverGlass: cover, amount: 0)
    workspace.setTestPageActive(true)

    let presentation = try #require(workspace.testPresentation)
    let feeder = try #require(presentation.phases[2].sections.flatMap(\.controls).first)
    guard case let .choice(outputSignal) = feeder else {
        Issue.record("Output Signal debe ser una selección.")
        return
    }
    let deviceControls = presentation.phases[3].sections.flatMap(\.controls)
    guard case let .choice(colorMode) = deviceControls[1] else {
        Issue.record("Color Mode debe ser una selección.")
        return
    }
    workspace.handleTestIntent(.setChoice(
        controlID: colorMode.id,
        optionID: "rec709-gamma24"
    ))

    let updated = try #require(workspace.testPresentation)
    guard case let .choice(updatedOutput) = updated.phases[2].sections
        .flatMap(\.controls).first
    else {
        Issue.record("Output Signal debe permanecer publicada.")
        return
    }
    #expect(outputSignal.selectedID == "srgb")
    #expect(updatedOutput.selectedID == "srgb")
    #expect(workspace.modelDeviceDefinition?.colorModeID == "rec709-gamma24")
    #expect(abs((workspace.modelDeviceDefinition?.eotfGamma ?? 0) - 2.4) < 0.000_001)
}
