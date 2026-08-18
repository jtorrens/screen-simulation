import Foundation
import StudioMedia
import Testing
@testable import ScreenSimulationNative

@Test @MainActor func outputQueueOwnsSequentialJobLifecycle() async {
    let controller = NativeOutputQueueController()
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

@Test @MainActor func outputQueuePublishesFailureWithoutASecondLifecycleOwner() async {
    struct ExpectedFailure: LocalizedError {
        var errorDescription: String? { "fallo controlado" }
    }
    let controller = NativeOutputQueueController()
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

@Test @MainActor func outputQueueFreezesTheSavedSceneAtEnqueueTime() {
    let controller = NativeOutputQueueController()
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

@Test @MainActor func completedJobCanBeRequeuedWithoutChangingItsSnapshot() async {
    let controller = NativeOutputQueueController()
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
    #expect(try executor.captureSavedScene().snapshot.settingsDocument
        == capture.snapshot.settingsDocument)
}

private func outputQueueTestScene(name: String) -> SavedScene {
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
            settingsDocument: try! JSONSerialization.data(
                withJSONObject: ["settings": ["schema": PhysicalSettingsExchange.schema]]
            )
        )
    )
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
