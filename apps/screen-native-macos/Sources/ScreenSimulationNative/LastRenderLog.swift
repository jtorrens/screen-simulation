import Foundation
import StudioMedia

struct RenderFramePhaseBreakdown: Codable, Equatable, Sendable {
    struct Phase: Codable, Equatable, Sendable {
        let id: String
        let seconds: Double
    }

    let frame: Int
    let phases: [Phase]
    let totalSeconds: Double
}

struct FusionPhysicalTiming: Codable, Equatable, Sendable {
    let sourcePreparationSeconds: Double
    let physicalEvaluationSeconds: Double
    let fusedScreenCoverLensSeconds: Double?
    let sensorCaptureDevelopmentSeconds: Double?
    let physicalOrchestrationOverheadSeconds: Double?
    let gpuReadbackSeconds: Double

    static func resolve(
        sourcePreparationSeconds: Double,
        physicalEvaluationSeconds: Double,
        gpuReadbackSeconds: Double,
        diagnostics: [PhysicalStageDiagnostic]
    ) -> Self {
        let byStage = Dictionary(uniqueKeysWithValues: diagnostics.map { ($0.stage, $0) })
        let fusedStages: [PhysicalStageID] = [
            .screen(.emission), .screen(.subpixelGeometry), .screen(.panelUniformity),
            .screen(.panelLightSpread), .screen(.temporal), .screen(.coverGlass),
            .screen(.environment), .screen(.coverGlow), .capture(.geometry),
            .capture(.lens), .capture(.exposureShutter),
        ]
        let sensorStages: [PhysicalStageID] = [
            .capture(.sensorCollection), .capture(.sensorBloom),
            .capture(.sensorReadout), .capture(.developDemosaic),
        ]
        func commonElapsedNanoseconds(_ stages: [PhysicalStageID]) -> UInt64? {
            let values = stages.compactMap { byStage[$0]?.elapsedNanoseconds }
            guard values.count == stages.count, values.allSatisfy({ $0 > 0 }),
                  Set(values).count == 1 else { return nil }
            return values.first
        }
        let fusedSeconds = commonElapsedNanoseconds(fusedStages).map {
            Double($0) / 1_000_000_000
        }
        let sensorSeconds = commonElapsedNanoseconds(sensorStages).map {
            Double($0) / 1_000_000_000
        }
        let classified = byStage.count == PhysicalStageID.ordered.count
            && fusedSeconds != nil && sensorSeconds != nil
            && sourcePreparationSeconds.isFinite && sourcePreparationSeconds >= 0
            && physicalEvaluationSeconds.isFinite && physicalEvaluationSeconds >= 0
            && gpuReadbackSeconds.isFinite && gpuReadbackSeconds >= 0
            && fusedSeconds! + sensorSeconds! <= physicalEvaluationSeconds + 0.001
        return Self(
            sourcePreparationSeconds: sourcePreparationSeconds,
            physicalEvaluationSeconds: physicalEvaluationSeconds,
            fusedScreenCoverLensSeconds: classified ? fusedSeconds : nil,
            sensorCaptureDevelopmentSeconds: classified ? sensorSeconds : nil,
            physicalOrchestrationOverheadSeconds: classified ? max(
                0, physicalEvaluationSeconds - fusedSeconds! - sensorSeconds!
            ) : nil,
            gpuReadbackSeconds: gpuReadbackSeconds
        )
    }
}

@MainActor
final class LastRenderLogRecorder {
    enum TerminalState: String, Codable { case rendering, completed, failed, cancelled }

    private struct Document: Codable {
        let schema: String
        let schemaVersion: Int
        let jobID: UUID
        let sceneID: UUID
        let sceneName: String
        let startedAt: Date
        var updatedAt: Date
        var finishedAt: Date?
        var state: TerminalState
        var failure: String?
        let host: Host
        let configuration: StudioResolvedRenderConfiguration
        let outputPlan: RenderOutputPlan
        var completedFrames: Int
        let totalFrames: Int
        var frames: [RenderFramePhaseBreakdown]
        var aggregate: Aggregate
    }

    private struct Host: Codable {
        let operatingSystem: String
        let processorCount: Int
        let physicalMemoryBytes: UInt64
    }

    private struct Aggregate: Codable {
        var elapsedSeconds: Double
        var averageCompletedFrameSeconds: Double?
        var estimatedRemainingSeconds: Double?
        var phaseTotalsSeconds: [String: Double]
        var phaseAverageSeconds: [String: Double]
    }

    private let url: URL
    private let clock = ContinuousClock()
    private let startedInstant: ContinuousClock.Instant
    private var previousProgressInstant: ContinuousClock.Instant
    private var document: Document
    private var pendingWrite: Task<Void, Error>?
    private var pendingEnqueueError: Error?

    convenience init(job: NativeOutputQueueController.RenderJob) throws {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        try self.init(
            jobID: job.id, sceneID: job.scene.id, sceneName: job.scene.name,
            configuration: job.configuration, outputPlan: job.outputPlan,
            directory: support.appendingPathComponent(
            "SCREEN-SIMULATION/Diagnostics", isDirectory: true
            )
        )
    }

    init(
        jobID: UUID, sceneID: UUID, sceneName: String,
        configuration: StudioResolvedRenderConfiguration,
        outputPlan: RenderOutputPlan,
        directory: URL
    ) throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        url = directory.appendingPathComponent("LastRender.json")
        startedInstant = clock.now
        previousProgressInstant = startedInstant
        let now = Date()
        document = Document(
            schema: "ScreenSimulation.LastRenderLog",
            schemaVersion: 1,
            jobID: jobID,
            sceneID: sceneID,
            sceneName: sceneName,
            startedAt: now,
            updatedAt: now,
            finishedAt: nil,
            state: .rendering,
            failure: nil,
            host: .init(
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                processorCount: ProcessInfo.processInfo.processorCount,
                physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory
            ),
            configuration: configuration,
            outputPlan: outputPlan,
            completedFrames: 0,
            totalFrames: configuration.frameRange.count,
            frames: [],
            aggregate: .init(
                elapsedSeconds: 0,
                averageCompletedFrameSeconds: nil,
                estimatedRemainingSeconds: nil,
                phaseTotalsSeconds: [:],
                phaseAverageSeconds: [:]
            )
        )
        try persist()
    }

    func recordProgress(completed: Int, total: Int) {
        guard pendingEnqueueError == nil, completed > document.completedFrames,
              total == document.totalFrames else { return }
        let now = clock.now
        let frameNumber = document.configuration.firstFrame + completed - 1
        let elapsed = previousProgressInstant.duration(to: now).seconds
        previousProgressInstant = now
        if !document.frames.contains(where: { $0.frame == frameNumber }) {
            upsert(.init(
                frame: frameNumber,
                phases: [.init(id: "frame-total-unclassified", seconds: elapsed)],
                totalSeconds: elapsed
            ))
        }
        document.completedFrames = completed
        updateAggregate(now: now)
        enqueuePersist()
    }

    func record(_ frame: RenderFramePhaseBreakdown) {
        guard pendingEnqueueError == nil else { return }
        upsert(frame)
        updateAggregate(now: clock.now)
    }

    func finish(_ state: TerminalState, failure: String? = nil) async throws {
        if let pendingEnqueueError { throw pendingEnqueueError }
        let now = Date()
        document.state = state
        document.failure = failure
        document.finishedAt = now
        document.updatedAt = now
        updateAggregate(now: clock.now)
        try enqueuePersistThrowing()
        try await pendingWrite?.value
    }

    private func upsert(_ frame: RenderFramePhaseBreakdown) {
        if let index = document.frames.firstIndex(where: { $0.frame == frame.frame }) {
            document.frames[index] = frame
        } else {
            document.frames.append(frame)
            document.frames.sort { $0.frame < $1.frame }
        }
    }

    private func updateAggregate(now: ContinuousClock.Instant) {
        let elapsed = startedInstant.duration(to: now).seconds
        var totals: [String: Double] = [:]
        for frame in document.frames {
            for phase in frame.phases { totals[phase.id, default: 0] += phase.seconds }
        }
        let completed = document.completedFrames
        document.aggregate = .init(
            elapsedSeconds: elapsed,
            averageCompletedFrameSeconds: completed > 0 ? elapsed / Double(completed) : nil,
            estimatedRemainingSeconds: completed > 0
                ? elapsed * Double(document.totalFrames - completed) / Double(completed) : nil,
            phaseTotalsSeconds: totals,
            phaseAverageSeconds: totals.mapValues {
                document.frames.isEmpty ? 0 : $0 / Double(document.frames.count)
            }
        )
        document.updatedAt = Date()
    }

    private func enqueuePersist() {
        do { try enqueuePersistThrowing() }
        catch { pendingEnqueueError = error }
    }

    private func enqueuePersistThrowing() throws {
        let data = try encodedDocument()
        let destination = url
        let previous = pendingWrite
        pendingWrite = Task.detached(priority: .utility) {
            if let previous { try await previous.value }
            try data.write(to: destination, options: .atomic)
        }
    }

    private func persist() throws {
        try encodedDocument().write(to: url, options: .atomic)
    }

    private func encodedDocument() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }
}

extension Duration {
    var seconds: Double {
        let parts = components
        return Double(parts.seconds)
            + Double(parts.attoseconds) / 1_000_000_000_000_000_000
    }
}
