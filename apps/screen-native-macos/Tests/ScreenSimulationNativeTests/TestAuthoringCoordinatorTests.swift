import Metal
import ScreenSimulationPresentation
import Testing
@testable import ScreenSimulationNative

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
        subpixelGeometryAmount: 1,
        panelLightSpreadAmount: 1,
        capturePresetID: "iphone-16e-main-48mp",
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
        environmentPresetID: "environment-none",
        environmentAmount: 0,
        coverGlowAmount: 1,
        lensPresetID: "iphone-16e-main-integrated",
        lensAmount: 1,
        focusDistanceMeters: 0.15,
        shutterMotionAmount: 1,
        sensorBloomAmount: 1,
        sensorNoiseAmount: 1
    )
}

@Test func rustPublishesTheCompleteOrderedTestPipeline() throws {
    let snapshot = try RustTestAuthoringCoordinator.snapshot(
        selection: canonicalTestSelection(),
        selectedPreviewPhaseID: nil
    )

    #expect(snapshot.presentation.phases.map(\.label) == [
        "Origen", "Salida del feeder", "Mapeo e interpretación del dispositivo",
        "Trama del panel", "Dispersión de luz del panel", "Geometría relativa",
        "Cristal y entorno", "Resplandor del cristal", "Objetivo y proyección",
        "Exposición y obturador", "Crosstalk y bloom del sensor",
        "Sensor y CFA", "Ruido del sensor", "Revelado y demosaico",
    ])
    #expect(snapshot.presentation.selectedPhaseID == snapshot.presentation.phases[0].id)
    for index in 0..<(snapshot.presentation.phases.count - 1) {
        #expect(snapshot.presentation.phases[index].outputArtifactID
            == snapshot.presentation.phases[index + 1].inputArtifactID)
    }
    #expect(snapshot.previewResultByPhaseID[snapshot.presentation.phases[0].id]
        == .sourceACEScg)
    #expect(snapshot.previewResultByPhaseID[snapshot.presentation.phases[1].id]
        == .feederSignal)
    #expect(snapshot.previewResultByPhaseID[snapshot.presentation.phases[2].id]
        == .deviceInterpretation)
    #expect(snapshot.previewResultByPhaseID[snapshot.presentation.phases[3].id]
        == .panelStructure)
    #expect(snapshot.previewResultByPhaseID[snapshot.presentation.phases[4].id]
        == .panelLightSpread)
    #expect(snapshot.previewResultByPhaseID[snapshot.presentation.phases[5].id]
        == .relativeGeometry)
    #expect(snapshot.previewResultByPhaseID[snapshot.presentation.phases[6].id]
        == .coverEnvironment)
    #expect(snapshot.previewResultByPhaseID[snapshot.presentation.phases[7].id]
        == .coverGlow)
    #expect(snapshot.previewResultByPhaseID[snapshot.presentation.phases[8].id]
        == .lensProjection)
    #expect(snapshot.previewResultByPhaseID[snapshot.presentation.phases[9].id]
        == .shutterExposure)
    #expect(snapshot.previewResultByPhaseID[snapshot.presentation.phases[10].id]
        == .sensorBloom)
    #expect(snapshot.previewResultByPhaseID[snapshot.presentation.phases[11].id]
        == .sensorCfa)
    #expect(snapshot.previewResultByPhaseID[snapshot.presentation.phases[12].id]
        == .sensorNoise)
    #expect(snapshot.previewResultByPhaseID[snapshot.presentation.phases[13].id]
        == .developDemosaic)

    let controls = snapshot.presentation.phases[1].sections.flatMap(\.controls)
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
    let deviceControls = snapshot.presentation.phases[2].sections.flatMap(\.controls)
    guard case let .choice(colorMode) = deviceControls[1] else {
        Issue.record("Color Mode debe pertenecer a la fase del dispositivo.")
        return
    }
    #expect(colorMode.options.map(\.id) == ["srgb", "rec709-gamma24"])
    #expect(snapshot.presentation.previewControls.count == 1)
    #expect(snapshot.presentation.phases[0].characterScaleNote == nil)
    #expect(snapshot.presentation.phases[1].characterScaleNote == nil)
    #expect(snapshot.presentation.phases[2].characterScaleNote?.contains("1 = físico calibrado") == true)
    #expect(snapshot.presentation.phases[3].characterScaleNote?.contains("1 = físico calibrado") == true)
    guard case let .scalar(subpixel) = snapshot.presentation.phases[3].sections
        .flatMap(\.controls).first
    else {
        Issue.record("La trama debe ser un escalar publicado por Rust.")
        return
    }
    #expect(subpixel.value == 1)
    #expect(subpixel.minimum == 0)
    #expect(subpixel.maximum == 4)
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
    let feederPhase = presentation.phases[1]
    guard case let .choice(outputSignal) = feederPhase.sections.flatMap(\.controls).first else {
        Issue.record("Output Signal debe ser una selección.")
        return
    }

    workspace.handleTestIntent(.setChoice(
        controlID: outputSignal.id,
        optionID: "rec709-gamma24"
    ))
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
    workspace.handleTestIntent(.selectPhase(presentation.phases[2].id))
    for _ in 0..<2_000 {
        if workspace.physicalPublicationSummary.contains("publicado") { break }
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
    workspace.handleTestIntent(.selectPhase(presentation.phases[3].id))
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
    workspace.handleTestIntent(.setChoice(controlID: quality.id, optionID: "high"))
    presentation = try #require(workspace.testPresentation)

    workspace.handleTestIntent(.selectPhase(presentation.phases[4].id))
    for _ in 0..<2_000 {
        if workspace.requestedPhysicalIntermediate == .panelLightSpread,
           workspace.physicalPublicationSummary.contains("publicado") { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    let flatFrame = try #require(workspace.metalFrame)
    let flat = try workspace.metalDisplay.readLinearRGBA(flatFrame)

    workspace.handleTestIntent(.selectPhase(presentation.phases[7].id))
    for _ in 0..<2_000 {
        if workspace.requestedPhysicalIntermediate == .lensProjection,
           workspace.physicalPublicationSummary.contains("Lens/Projection"),
           workspace.physicalPublicationSummary.contains("publicado") { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    let projectedFrame = try #require(workspace.metalFrame)
    let projected = try workspace.metalDisplay.readLinearRGBA(projectedFrame)

    workspace.changePhysicalStageAmount(0, stage: .capture(.geometry))
    for _ in 0..<2_000 {
        if let replacement = workspace.metalFrame,
           replacement.texture !== projectedFrame.texture,
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
    #expect(meanAbsoluteDifference > 0.01)
    let geometryDifference = zip(projected, geometryDisabled).reduce(Float.zero) {
        $0 + abs($1.0 - $1.1)
    } / Float(projected.count)
    #expect(geometryDifference > 0.01)
}

@Test func deviceIntentReturnsOneAtomicResolvedSelection() throws {
    let current = canonicalTestSelection()
    let snapshot = try RustTestAuthoringCoordinator.snapshot(
        selection: current,
        selectedPreviewPhaseID: nil
    )
    let deviceControl = snapshot.presentation.phases[2].sections
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
        .deviceSignal,
        .panelEmission,
        .subpixelRadiance,
        .panelLightSpread,
        .relativeGeometry,
        .coverEnvironment,
        .coverGlow,
        .lensProjection,
        .shutterMotion,
        .sensorBloom,
        .sensorNoise,
        .rawMosaic,
        .developedACEScg,
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
    for _ in 0..<2_000 {
        if workspace.physicalPublicationSummary.contains("publicado") { break }
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
    let feeder = try #require(presentation.phases[1].sections.flatMap(\.controls).first)
    guard case let .choice(outputSignal) = feeder else {
        Issue.record("Output Signal debe ser una selección.")
        return
    }
    let deviceControls = presentation.phases[2].sections.flatMap(\.controls)
    guard case let .choice(colorMode) = deviceControls[1] else {
        Issue.record("Color Mode debe ser una selección.")
        return
    }
    workspace.handleTestIntent(.setChoice(
        controlID: colorMode.id,
        optionID: "rec709-gamma24"
    ))

    let updated = try #require(workspace.testPresentation)
    guard case let .choice(updatedOutput) = updated.phases[1].sections
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
