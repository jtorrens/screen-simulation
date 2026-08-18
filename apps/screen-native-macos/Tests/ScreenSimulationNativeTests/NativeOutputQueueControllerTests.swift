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
    #expect(controller.jobs.first?.configuration.motionBlurEnabled == true)
    #expect(controller.jobs.first?.configuration.motionSamples == 8)
}

@Test @MainActor func completedJobCanBeRequeuedWithoutChangingItsSnapshot() async throws {
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

    #expect(controller.requeueCompletedJob(id: completed.id))
    #expect(controller.jobs.first?.state == .pending)
    #expect(controller.jobs.first?.progress == 0)
    #expect(controller.jobs.first?.detail == "Pendiente")
    #expect(controller.jobs.first?.scene.snapshot == snapshot)
    #expect(controller.jobs.first?.configuration == configuration)
    #expect(!controller.requeueCompletedJob(id: completed.id))
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

@Test @MainActor func pendingJobCanBeRemovedWithoutTouchingAnyOutput() throws {
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
    #expect(controller.removePendingJob(id: job.id))
    #expect(controller.jobs.isEmpty)
    #expect(FileManager.default.fileExists(atPath: outputURL.path))
    #expect(!controller.removePendingJob(id: job.id))
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
    #expect(try executor.captureSavedScene().snapshot.authoring
        == capture.snapshot.authoring)
}

private func outputQueueTestScene(name: String) -> SavedScene {
    let input = StudioColorInputTransform.catalog.first { $0.id == "srgb-encoded-rec709" }!
    let output = StudioColorOutputTransform.catalog.first { $0.id == "aces2-srgb-sdr-100" }!
    let device = try! RustDeviceCatalog.builtIns().first!
    let selection = try! RustTestAuthoringCoordinator.defaultSelection(
        inputTransformID: input.id, deviceID: device.id, frameRate: .fps24
    )
    let authoring = SceneAuthoringDocument(
        context: .init(
            selection: selection, sourceInputTransformID: input.id,
            sourceAlphaMode: StudioAlphaMode.ignore.rawValue,
            sourceColorModel: StudioSignalColorModel.rgb.rawValue,
            sourceYUVMatrix: StudioSignalMatrix.bt709.rawValue,
            sourceSignalRange: StudioSignalRange.full.rawValue,
            sourcePlacementID: "fit", previewOutputTransformID: output.id,
            previewPhaseID: "recording-codec",
            environmentResource: .init(kind: .procedural, fileName: nil, absolutePath: nil, inputTransformID: nil),
            referenceResource: .init(kind: .none, fileName: nil, absolutePath: nil, inputTransformID: nil, alphaMode: nil, signalColorModel: nil, signalMatrix: nil, signalRange: nil, placementID: nil, corners: [])
        ), model: .init(screen: .init(storedAmount: 1, isBypassed: false), stages: []), environmentCalibration: nil
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
        outputType: .standard,
        jobName: "QueueTest",
        overwritePolicy: .failIfExists,
        fusionScene: nil,
        composition: .deviceOnly,
        motionBlurEnabled: true,
        motionSamples: 8,
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
