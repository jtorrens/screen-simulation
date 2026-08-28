import Foundation
import StudioMedia
import Testing
@testable import ScreenSimulationNative

@Test @MainActor func lastRenderLogIsLiveDetailedAndReplacedByTheNextAttempt() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("last-render-log-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let configuration = lastRenderConfiguration()
    let plan = RenderOutputPlan(
        kind: .singleFile,
        destination: directory.appendingPathComponent("render.exr"),
        generatedRelativePaths: ["render.exr"]
    )
    let firstID = UUID()
    let first = try LastRenderLogRecorder(
        jobID: firstID, sceneID: UUID(), sceneName: "First",
        configuration: configuration, outputPlan: plan, directory: directory
    )
    first.record(.init(
        frame: 10,
        phases: [
            .init(id: "physical-fused-screen-cover-lens", seconds: 2.0),
            .init(id: "physical-sensor-capture-development", seconds: 1.4),
            .init(id: "physical-orchestration-overhead", seconds: 0.1),
            .init(id: "device-color-transform-encode-write", seconds: 0.8),
        ],
        totalSeconds: 4.3
    ))
    first.recordProgress(completed: 1, total: 2)
    try await first.finish(.completed)

    let url = directory.appendingPathComponent("LastRender.json")
    let firstJSON = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    )
    #expect(firstJSON["schema"] as? String == "ScreenSimulation.LastRenderLog")
    #expect(firstJSON["state"] as? String == "completed")
    #expect((firstJSON["frames"] as? [[String: Any]])?.count == 1)
    let aggregate = try #require(firstJSON["aggregate"] as? [String: Any])
    let totals = try #require(aggregate["phaseTotalsSeconds"] as? [String: Double])
    #expect(totals["physical-fused-screen-cover-lens"] == 2.0)
    #expect(totals["physical-sensor-capture-development"] == 1.4)
    #expect(totals["physical-orchestration-overhead"] == 0.1)

    let secondID = UUID()
    let second = try LastRenderLogRecorder(
        jobID: secondID, sceneID: UUID(), sceneName: "Second",
        configuration: configuration, outputPlan: plan, directory: directory
    )
    let secondJSON = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
    )
    #expect(secondJSON["jobID"] as? String == secondID.uuidString)
    #expect(secondJSON["state"] as? String == "rendering")
    #expect((secondJSON["frames"] as? [[String: Any]])?.isEmpty == true)
    try await second.finish(.cancelled)
}

@Test func fusionPhysicalTimingResolvesExistingExclusiveExecutionBlocks() throws {
    let diagnostics = PhysicalStageID.ordered.map { stage in
        let elapsed: UInt64 = switch stage {
        case .capture(.sensorCollection), .capture(.sensorBloom),
             .capture(.sensorReadout), .capture(.developDemosaic):
            1_250_000_000
        case .capture(.computationalCapture):
            0
        default:
            2_000_000_000
        }
        return PhysicalStageDiagnostic(
            stage: stage, state: .complete, progress: 1,
            elapsedNanoseconds: elapsed, message: ""
        )
    }
    let timing = FusionPhysicalTiming.resolve(
        sourcePreparationSeconds: 0.02,
        physicalEvaluationSeconds: 3.4,
        gpuReadbackSeconds: 0.1,
        diagnostics: diagnostics
    )
    #expect(timing.fusedScreenCoverLensSeconds == 2)
    #expect(timing.sensorCaptureDevelopmentSeconds == 1.25)
    let overhead = try #require(timing.physicalOrchestrationOverheadSeconds)
    #expect(abs(overhead - 0.15) < 0.000_001)
}

@Test func fusionPhysicalTimingKeepsRenderingWhenEvidenceCannotBeClassified() {
    let timing = FusionPhysicalTiming.resolve(
        sourcePreparationSeconds: 0.02,
        physicalEvaluationSeconds: 3.4,
        gpuReadbackSeconds: 0.1,
        diagnostics: []
    )
    #expect(timing.fusedScreenCoverLensSeconds == nil)
    #expect(timing.sensorCaptureDevelopmentSeconds == nil)
    #expect(timing.physicalOrchestrationOverheadSeconds == nil)
    #expect(timing.physicalEvaluationSeconds == 3.4)
}

private func lastRenderConfiguration() -> StudioResolvedRenderConfiguration {
    StudioResolvedRenderConfiguration(
        renderMode: .final,
        jobName: "LogTest",
        versionSuffix: "",
        overwritePolicy: .failIfExists,
        fusionScene: nil,
        composition: .deviceAndSpillTogether,
        spillDeliveryMode: .physicalLinear,
        motionBlurMode: .disabled,
        motionSamples: 2,
        raster: .init(width: 16, height: 9, placementID: "fit"),
        format: .openEXR,
        pipeline: .aces,
        target: .acescg,
        peakNits: 0,
        display: nil,
        view: nil,
        vfxInterchangeEncodingID: nil,
        pixelEncoding: .rgba16Float,
        signalRange: .full,
        alpha: .straight,
        includeAudio: false,
        frameRate: .fps24,
        firstFrame: 10,
        lastFrame: 11
    )
}
