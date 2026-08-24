import Foundation
import StudioColor
import StudioMedia
import Testing
@testable import ScreenSimulationNative

@Test @MainActor func outputQueueOwnsSequentialJobLifecycle() async throws {
    let controller = try queueTestController()
    let configuration = outputQueueTestConfiguration()
    controller.enqueue(
        scene: outputQueueTestScene(name: "Primera"),
        generatedEnvironmentEXR: nil,
        outputPlan: queueTestPlan("/tmp/first.mov"),
        configuration: configuration
    )
    controller.enqueue(
        scene: outputQueueTestScene(name: "Segunda"),
        generatedEnvironmentEXR: nil,
        outputPlan: queueTestPlan("/tmp/second.mov"),
        configuration: configuration
    )

    controller.run(operation: { job, progress in
        progress(1, 2)
        progress(2, 2)
        return job.destination
    }, onFailure: { _ in })

    while controller.isRendering { await Task.yield() }
    #expect(controller.jobs.map(\.state) == [.completed, .completed])
    #expect(controller.jobs.map(\.progress) == [1, 1])
    #expect(controller.jobs.map(\.detail) == ["first.mov", "second.mov"])
}

@Test @MainActor func outputCollisionIsAuthorizedImmediatelyBeforeTheAttempt() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("render-preflight-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let outputURL = root.appendingPathComponent("test_Device.mov")
    try Data([1, 2, 3]).write(to: outputURL)

    let controller = try queueTestController()
    controller.enqueue(
        scene: outputQueueTestScene(name: "Colisión"),
        generatedEnvironmentEXR: nil,
        outputPlan: queueTestPlan(outputURL.path),
        configuration: outputQueueTestConfiguration()
    )
    var events: [String] = []
    controller.run(
        preflight: { job in
            events.append("preflight")
            let collision = try job.outputPlan.inspectCollision()
            #expect(collision.requiresConfirmation)
            return .replaceGeneratedFiles
        },
        operation: { job, _ in
            events.append("operation")
            #expect(job.configuration.overwritePolicy == .replaceGeneratedFiles)
            return job.destination
        },
        onFailure: { _ in }
    )

    while controller.isRendering { await Task.yield() }
    #expect(events == ["preflight", "operation"])
    #expect(controller.jobs.first?.state == .completed)
    #expect(controller.jobs.first?.configuration.overwritePolicy == .replaceGeneratedFiles)
}

@Test @MainActor func cancellingOutputCollisionPreflightLeavesTheJobPending() async throws {
    let controller = try queueTestController()
    controller.enqueue(
        scene: outputQueueTestScene(name: "Cancelar colisión"),
        generatedEnvironmentEXR: nil,
        outputPlan: queueTestPlan("/tmp/cancel-preflight.mov"),
        configuration: outputQueueTestConfiguration()
    )
    var operationRan = false
    controller.run(
        preflight: { _ in nil },
        operation: { job, _ in
            operationRan = true
            return job.destination
        },
        onFailure: { _ in }
    )

    await Task.yield()
    #expect(!operationRan)
    #expect(controller.jobs.first?.state == .pending)
}

@Test @MainActor func eachQueuedAttemptRechecksFilesProducedByAnEarlierJob() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("render-sequential-preflight-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let outputURL = root.appendingPathComponent("test_Device.mov")
    let plan = queueTestPlan(outputURL.path)
    let controller = try queueTestController()
    for name in ["Primero", "Segundo"] {
        controller.enqueue(
            scene: outputQueueTestScene(name: name), generatedEnvironmentEXR: nil,
            outputPlan: plan, configuration: outputQueueTestConfiguration()
        )
    }
    var preflightCollisions: [Bool] = []
    controller.run(
        preflight: { job in
            let collision = try job.outputPlan.inspectCollision().requiresConfirmation
            preflightCollisions.append(collision)
            return collision ? .replaceGeneratedFiles : job.configuration.overwritePolicy
        },
        operation: { job, _ in
            if FileManager.default.fileExists(atPath: job.destination.path) {
                #expect(job.configuration.overwritePolicy == .replaceGeneratedFiles)
            }
            try Data(job.scene.name.utf8).write(to: job.destination, options: .atomic)
            return job.destination
        },
        onFailure: { _ in }
    )

    while controller.isRendering { await Task.yield() }
    #expect(preflightCollisions == [false, true])
    #expect(controller.jobs.map(\.state) == [.completed, .completed])
    #expect(controller.jobs[1].configuration.overwritePolicy == .replaceGeneratedFiles)
}

@Test @MainActor func outputQueuePublishesFailureWithoutASecondLifecycleOwner() async throws {
    struct ExpectedFailure: LocalizedError {
        var errorDescription: String? { "fallo controlado" }
    }
    let controller = try queueTestController()
    controller.enqueue(
        scene: outputQueueTestScene(name: "Fallo"),
        generatedEnvironmentEXR: nil,
        outputPlan: queueTestPlan("/tmp/failure.mov"),
        configuration: outputQueueTestConfiguration()
    )
    var failure: String?
    controller.run(
        operation: { _, _ in throw ExpectedFailure() },
        onFailure: { failure = $0 }
    )
    while controller.isRendering { await Task.yield() }
    #expect(controller.jobs.first?.state == .failed)
    #expect(controller.jobs.first?.detail == "fallo controlado")
    #expect(failure == "fallo controlado")
}

@Test @MainActor func outputQueuePublishesElapsedEstimateAndCancelsWithoutLosingItsOwner() async throws {
    let controller = try queueTestController()
    controller.enqueue(
        scene: outputQueueTestScene(name: "Cancelar"),
        generatedEnvironmentEXR: nil,
        outputPlan: queueTestPlan("/tmp/cancel.mov"),
        configuration: outputQueueTestConfiguration()
    )
    var cancellationWasObserved = false
    controller.run(operation: { job, progress in
        progress(1, 4)
        do {
            try await Task.sleep(for: .seconds(10))
            return job.destination
        } catch is CancellationError {
            cancellationWasObserved = true
            throw CancellationError()
        }
    }, onFailure: { _ in })

    while controller.jobs.first?.progress != 0.25 { await Task.yield() }
    try await Task.sleep(for: .milliseconds(20))
    let job = try #require(controller.jobs.first)
    let timing = try #require(controller.timing(for: job.id))
    #expect(timing.elapsedSeconds > 0)
    #expect((timing.approximateRemainingSeconds ?? 0) > timing.elapsedSeconds)

    controller.cancel()
    while controller.isRendering { await Task.yield() }
    #expect(cancellationWasObserved)
    #expect(controller.jobs.first?.state == .cancelled)
    #expect(controller.jobs.first?.detail == "Cancelado")
    #expect(controller.timing(for: job.id) == nil)
}

@Test @MainActor func outputQueueFreezesTheSavedSceneAtEnqueueTime() throws {
    let controller = try queueTestController()
    var scene = outputQueueTestScene(name: "Guardada")
    controller.enqueue(
        scene: scene,
        generatedEnvironmentEXR: Data([1, 2, 3]),
        outputPlan: queueTestPlan("/tmp/frozen.mov"),
        configuration: outputQueueTestConfiguration()
    )
    scene.name = "Modificada después"

    #expect(controller.jobs.first?.scene.name == "Guardada")
    #expect(controller.jobs.first?.generatedEnvironmentEXR == Data([1, 2, 3]))
    #expect(controller.jobs.first?.scene.snapshot == outputQueueTestScene(name: "Otra").snapshot)
    #expect(controller.jobs.first?.configuration.motionBlurMode == .physical)
    #expect(controller.jobs.first?.configuration.motionSamples == 8)
}

@Test @MainActor func outputQueueAttemptResolvesCurrentDefaultsForItsFrozenProfileIDs() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-queue-profile-attempt-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let libraryStore = try GlobalLibraryStore(
        documentURL: root.appendingPathComponent("library.json")
    )
    var devices = try RustDeviceCatalog.builtIns()
    let covers = try RustCoverGlassCatalog.builtIns()
    let deviceIndex = try #require(devices.firstIndex {
        $0.maximumWhiteLuminance > $0.minimumWhiteLuminance
    })
    let selectedDevice = devices[deviceIndex]
    let expected = selectedDevice.minimumWhiteLuminance
        + (selectedDevice.maximumWhiteLuminance - selectedDevice.minimumWhiteLuminance) * 0.75

    let initial = outputQueueTestScene(name: "Autoría congelada")
    let oldAuthoring = initial.snapshot.authoring
    let authoring = SceneAuthoringDocument(
        profiles: .init(
            deviceID: selectedDevice.id,
            coverGlassID: selectedDevice.defaultCoverGlassPresetID,
            captureID: oldAuthoring.profiles.captureID,
            lensID: oldAuthoring.profiles.lensID,
            environmentID: oldAuthoring.profiles.environmentID,
            deliveryID: oldAuthoring.profiles.deliveryID,
            recordingID: oldAuthoring.profiles.recordingID
        ),
        overrides: [], modelOverrides: oldAuthoring.modelOverrides,
        context: oldAuthoring.context, environmentCalibration: nil
    )
    let snapshot = SavedSceneSnapshot(
        source: initial.snapshot.source,
        currentFrame: initial.snapshot.currentFrame,
        viewerZoom: initial.snapshot.viewerZoom,
        viewerPanX: initial.snapshot.viewerPanX,
        viewerPanY: initial.snapshot.viewerPanY,
        viewerIsFitted: initial.snapshot.viewerIsFitted,
        authoring: authoring,
        generatedEnvironment: initial.snapshot.generatedEnvironment,
        tracking: initial.snapshot.tracking
    )
    let frozenScene = SavedScene(
        id: initial.id, name: initial.name,
        thumbnailFileName: initial.thumbnailFileName, snapshot: snapshot
    )
    let controller = try NativeOutputQueueController(
        store: RenderQueueStore(directoryURL: root.appendingPathComponent("queue"))
    )
    controller.enqueue(
        scene: frozenScene, generatedEnvironmentEXR: nil,
        outputPlan: queueTestPlan(root.appendingPathComponent("attempt.mov").path),
        configuration: outputQueueTestConfiguration()
    )

    // Defaults change after enqueue. The job must retain its ids/overrides while the attempt
    // resolves the new definition of that exact id.
    devices[deviceIndex].whiteLevelNits = expected
    try libraryStore.save(.init(devices: devices, coverGlasses: covers))
    var resolvedWhite: Double?
    controller.run(operation: { job, _ in
        let workspace = WorkspaceModel(globalLibraryStore: libraryStore)
        await workspace.openSavedScene(job.scene, undoManager: nil)
        let controls = (workspace.testPresentation?.previewControls ?? [])
            + (workspace.testPresentation?.phases ?? []).flatMap {
                $0.sections.flatMap(\.controls)
            }
        if let descriptor = controls.first(where: { $0.id == "white-luminance" }),
           case let .scalar(control) = descriptor {
            resolvedWhite = control.value
        }
        return job.destination
    }, onFailure: { _ in })
    while controller.isRendering { await Task.yield() }

    #expect(controller.jobs.first?.scene.snapshot.authoring.profiles.deviceID
        == selectedDevice.id)
    #expect(controller.jobs.first?.scene.snapshot.authoring.overrides.isEmpty == true)
    #expect(resolvedWhite == expected)
}

@Test @MainActor func historicalRerenderCreatesALinkedJobWithoutChangingItsOrigin() async throws {
    let controller = try queueTestController()
    controller.enqueue(
        scene: outputQueueTestScene(name: "Congelada"),
        generatedEnvironmentEXR: Data([4, 2]),
        outputPlan: queueTestPlan("/tmp/requeue.mov"),
        configuration: outputQueueTestConfiguration()
    )
    controller.run(operation: { job, _ in job.destination }, onFailure: { _ in })
    while controller.isRendering { await Task.yield() }
    let completed = try! #require(controller.jobs.first)
    let snapshot = completed.scene.snapshot
    let configuration = completed.configuration

    controller.enqueue(
        scene: completed.scene,
        generatedEnvironmentEXR: completed.generatedEnvironmentEXR,
        outputPlan: completed.outputPlan,
        configuration: completed.configuration,
        derivedFromJobID: completed.id
    )
    #expect(controller.jobs.count == 2)
    #expect(controller.jobs[0].state == .completed)
    #expect(controller.jobs[1].state == .pending)
    #expect(controller.jobs[1].derivedFromJobID == completed.id)
    #expect(controller.jobs[1].scene.snapshot == snapshot)
    #expect(controller.jobs[1].configuration == configuration)
}

@Test @MainActor func outputQueuePersistsFrozenJobsAndPausedStateAcrossSessions() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("render-queue-persistence-\(UUID().uuidString)")
    let store = try RenderQueueStore(directoryURL: root)
    let first = try NativeOutputQueueController(store: store)
    first.enqueue(
        scene: outputQueueTestScene(name: "Persistida"),
        generatedEnvironmentEXR: Data([9, 4]),
        outputPlan: queueTestPlan("/tmp/persisted.mov"),
        configuration: outputQueueTestConfiguration()
    )
    first.pause()

    let restored = try NativeOutputQueueController(store: store)
    #expect(restored.isPaused)
    #expect(restored.jobs.count == 1)
    #expect(restored.jobs[0].scene.name == "Persistida")
    #expect(restored.jobs[0].generatedEnvironmentEXR == Data([9, 4]))
    #expect(restored.jobs[0].configuration.overwritePolicy == .failIfExists)
    #expect(restored.jobs[0].state == .pending)
}

@Test @MainActor func renderQueueV10StrictlyRequiresPreviewFinalRasterAndOutputIdentity() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("render-queue-v10-strict-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try RenderQueueStore(directoryURL: root)
    let controller = try NativeOutputQueueController(store: store)
    controller.enqueue(
        scene: outputQueueTestScene(name: "Contrato v10"), generatedEnvironmentEXR: nil,
        outputPlan: queueTestPlan("/tmp/v10.mov"),
        configuration: outputQueueTestConfiguration()
    )
    let encoded = try Data(contentsOf: store.documentURL)
    let rootObject = try #require(
        try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    )
    #expect(rootObject["schema"] as? String == "ScreenSimulation.RenderQueue.v10")

    var legacy = rootObject
    var jobs = try #require(legacy["jobs"] as? [[String: Any]])
    var configuration = try #require(jobs[0]["configuration"] as? [String: Any])
    configuration.removeValue(forKey: "motionBlurMode")
    configuration["motionBlurEnabled"] = true
    jobs[0]["configuration"] = configuration
    legacy["jobs"] = jobs
    try JSONSerialization.data(withJSONObject: legacy).write(
        to: store.documentURL, options: .atomic
    )
    #expect(throws: (any Error).self) { try store.load() }

    var missingVersionSuffix = rootObject
    var identityJobs = try #require(missingVersionSuffix["jobs"] as? [[String: Any]])
    var identityConfiguration = try #require(identityJobs[0]["configuration"] as? [String: Any])
    identityConfiguration.removeValue(forKey: "versionSuffix")
    identityJobs[0]["configuration"] = identityConfiguration
    missingVersionSuffix["jobs"] = identityJobs
    try JSONSerialization.data(withJSONObject: missingVersionSuffix).write(
        to: store.documentURL, options: .atomic
    )
    #expect(throws: (any Error).self) { try store.load() }

    var missingRaster = rootObject
    var rasterJobs = try #require(missingRaster["jobs"] as? [[String: Any]])
    var rasterConfiguration = try #require(rasterJobs[0]["configuration"] as? [String: Any])
    rasterConfiguration.removeValue(forKey: "raster")
    rasterJobs[0]["configuration"] = rasterConfiguration
    missingRaster["jobs"] = rasterJobs
    try JSONSerialization.data(withJSONObject: missingRaster).write(
        to: store.documentURL, options: .atomic
    )
    #expect(throws: (any Error).self) { try store.load() }

    var missingSpill = rootObject
    var spillJobs = try #require(missingSpill["jobs"] as? [[String: Any]])
    var spillConfiguration = try #require(spillJobs[0]["configuration"] as? [String: Any])
    spillConfiguration.removeValue(forKey: "spillDeliveryMode")
    spillJobs[0]["configuration"] = spillConfiguration
    missingSpill["jobs"] = spillJobs
    try JSONSerialization.data(withJSONObject: missingSpill).write(
        to: store.documentURL, options: .atomic
    )
    #expect(throws: (any Error).self) { try store.load() }
}

@Test @MainActor func inactiveJobCanBeRemovedWithoutTouchingAnyOutput() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("render-queue-remove-\(UUID().uuidString)")
    let outputURL = root.appendingPathComponent("existing.mov")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data([1, 2, 3]).write(to: outputURL)
    let controller = try NativeOutputQueueController(
        store: RenderQueueStore(directoryURL: root.appendingPathComponent("queue"))
    )
    controller.enqueue(
        scene: outputQueueTestScene(name: "Eliminar"), generatedEnvironmentEXR: nil,
        outputPlan: queueTestPlan(outputURL.path), configuration: outputQueueTestConfiguration()
    )
    let job = try #require(controller.jobs.first)
    #expect(controller.removeInactiveJob(id: job.id))
    #expect(controller.jobs.isEmpty)
    #expect(FileManager.default.fileExists(atPath: outputURL.path))
    #expect(!controller.removeInactiveJob(id: job.id))
}

@Test @MainActor func terminalCleanupRetainsOnlyPendingAndRenderingStates() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("render-queue-terminal-cleanup-\(UUID().uuidString)")
    let store = try RenderQueueStore(directoryURL: root)
    let scene = outputQueueTestScene(name: "Estados")
    let configuration = outputQueueTestConfiguration()
    let states: [NativeOutputQueueController.RenderJob.State] = [
        .pending, .rendering, .completed, .failed, .cancelled,
    ]
    let jobs = states.enumerated().map { index, state in
        NativeOutputQueueController.RenderJob(
            scene: scene,
            generatedEnvironmentEXR: nil,
            outputPlan: queueTestPlan("/tmp/state-\(index).mov"),
            configuration: configuration,
            state: state,
            progress: state == .completed ? 1 : 0,
            detail: state.rawValue
        )
    }
    try store.save(.init(jobs: jobs))
    let controller = try NativeOutputQueueController(store: store)

    // A persisted rendering record is restored as pending before cleanup.
    controller.clearTerminalJobs()
    #expect(controller.jobs.map(\.state) == [.pending, .pending])
    #expect(!controller.jobs.contains { $0.id == jobs[4].id })
    #expect(controller.removeInactiveJob(id: jobs[0].id))
}

@Test func completedFailedAndCancelledAreTheOnlyHistoricalRerenderStates() {
    typealias State = NativeOutputQueueController.RenderJob.State
    #expect(State.completed.isTerminal)
    #expect(State.failed.isTerminal)
    #expect(State.cancelled.isTerminal)
    #expect(!State.pending.isTerminal)
    #expect(!State.rendering.isTerminal)
}

@Test @MainActor func renderingJobRestoresAsPendingWithoutAutoRun() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("render-queue-interrupted-\(UUID().uuidString)")
    let store = try RenderQueueStore(directoryURL: root)
    let controller = try NativeOutputQueueController(store: store)
    controller.enqueue(
        scene: outputQueueTestScene(name: "Interrumpida"), generatedEnvironmentEXR: nil,
        outputPlan: queueTestPlan("/tmp/interrupted.mov"), configuration: outputQueueTestConfiguration()
    )
    controller.run(operation: { _, _ in
        try await Task.sleep(for: .seconds(10))
        throw CancellationError()
    }, onFailure: { _ in })
    while controller.jobs.first?.state != .rendering { await Task.yield() }
    let restored = try NativeOutputQueueController(store: store)
    #expect(!restored.isRendering)
    #expect(restored.jobs.first?.state == .pending)
    #expect(restored.jobs.first?.detail == "Interrumpido al cerrar la aplicación")
    controller.cancel()
}

@Test @MainActor func isolatedQueueWorkspaceRestoresAStrictSavedSceneWithoutPriorState() async throws {
    let source = WorkspaceModel()
    let device = try #require(try RustDeviceCatalog.builtIns().first)
    let cover = try #require(try RustCoverGlassCatalog.builtIns().first {
        $0.id == device.defaultCoverGlassPresetID
    })
    source.selectModelDevice(device, coverGlass: cover)
    let capture = try source.captureSavedScene()
    let id = UUID()
    let scene = SavedScene(
        id: id,
        name: "Render aislado",
        thumbnailFileName: "\(id.uuidString.lowercased()).png",
        snapshot: capture.snapshot
    )

    let executor = WorkspaceModel()
    await executor.openSavedScene(scene, undoManager: nil)

    #expect(executor.errorMessage == nil)
    let reopened = try executor.captureSavedScene().snapshot.authoring
    #expect(reopened == capture.snapshot.authoring)
}

private func outputQueueTestScene(name: String) -> SavedScene {
    let input = StudioColorInputTransform.catalog.first { $0.id == "srgb-encoded-rec709" }!
    let output = StudioColorOutputTransform.catalog.first { $0.id == "aces2-srgb-sdr-100" }!
    let device = try! RustDeviceCatalog.builtIns().first!
    let selection = try! RustTestAuthoringCoordinator.defaultSelection(
        inputTransformID: input.id, deviceID: device.id, frameRate: .fps24
    )
    let coverGlass = try! RustCoverGlassCatalog.builtIns().first!
    let authoring = SceneAuthoringDocument(
        profiles: .init(
            deviceID: device.id, coverGlassID: coverGlass.id,
            captureID: selection.capturePresetID, lensID: selection.lensPresetID,
            environmentID: selection.environmentSourceID,
            deliveryID: selection.deliveryPresetID,
            recordingID: selection.recordingProfileID
        ),
        overrides: [],
        modelOverrides: .init(screen: nil, stages: []),
        context: .init(
            sourceInputTransformID: input.id,
            sourceAlphaMode: StudioAlphaMode.ignore.rawValue,
            sourceColorModel: StudioSignalColorModel.rgb.rawValue,
            sourceYUVMatrix: StudioSignalMatrix.bt709.rawValue,
            sourceSignalRange: StudioSignalRange.full.rawValue,
            sourcePlacementID: "fit", previewOutputTransformID: output.id,
            previewPhaseID: "recording-codec",
            referencePlateID: "vfx-checker",
            environmentResource: .init(kind: .procedural, fileName: nil, absolutePath: nil, inputTransformID: nil),
            referenceResource: .init(kind: .none, fileName: nil, absolutePath: nil, inputTransformID: nil, alphaMode: nil, signalColorModel: nil, signalMatrix: nil, signalRange: nil, placementID: nil, corners: [])
        ), environmentCalibration: nil
    )
    let id = UUID()
    return SavedScene(
        id: id,
        name: name,
        thumbnailFileName: "\(id.uuidString.lowercased()).png",
        snapshot: SavedSceneSnapshot(
            source: .init(
                kind: .syntheticPattern,
                patternRawValue: SyntheticPattern.eyeChart.rawValue,
                assets: [],
                missingMedia: nil
            ),
            currentFrame: 0,
            viewerZoom: 1,
            viewerPanX: 0,
            viewerPanY: 0,
            viewerIsFitted: true,
            authoring: authoring
        )
    )
}

@MainActor private func queueTestController() throws -> NativeOutputQueueController {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("render-queue-test-\(UUID().uuidString)")
    return try NativeOutputQueueController(store: RenderQueueStore(directoryURL: root))
}

private func outputQueueTestConfiguration() -> StudioResolvedRenderConfiguration {
    StudioResolvedRenderConfiguration(
        renderMode: .final,
        jobName: "QueueTest",
        versionSuffix: "_v07",
        overwritePolicy: .failIfExists,
        fusionScene: nil,
        composition: .deviceAndSpillTogether,
        spillDeliveryMode: .physicalLinear,
        motionBlurMode: .physical,
        motionSamples: 8, raster: .init(width: 1920, height: 1080, placementID: "fit"),
        format: .proRes4444,
        pipeline: .aces,
        target: .sdr,
        peakNits: 100,
        display: "sRGB",
        view: "ACES 2.0 - SDR 100 nits (Rec.709)",
        vfxInterchangeEncodingID: nil,
        pixelEncoding: .yuv44412,
        signalRange: .video,
        alpha: .straight,
        includeAudio: false,
        frameRate: .fps24,
        firstFrame: 0,
        lastFrame: 1
    )
}

private func queueTestPlan(_ path: String) -> RenderOutputPlan {
    let url = URL(fileURLWithPath: path)
    return RenderOutputPlan(
        kind: .singleFile,
        destination: url,
        generatedRelativePaths: [url.lastPathComponent]
    )
}
