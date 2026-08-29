import Foundation
import StudioMedia

@MainActor
final class NativeOutputQueueController: ObservableObject {
    struct RenderTiming: Equatable, Sendable {
        let elapsedSeconds: TimeInterval
        let approximateRemainingSeconds: TimeInterval?
        let lastCompletedFrameSeconds: TimeInterval?
        let averageCompletedFrameSeconds: TimeInterval?
    }

    struct TerminalTiming: Codable, Equatable, Sendable {
        let totalSeconds: TimeInterval
        let averageCompletedFrameSeconds: TimeInterval?
    }

    struct RenderJob: Codable, Identifiable {
        enum State: String, Codable {
            case pending, rendering, completed, failed, cancelled

            var isTerminal: Bool {
                switch self {
                case .completed, .failed, .cancelled: true
                case .pending, .rendering: false
                }
            }
        }
        let id: UUID
        let derivedFromJobID: UUID?
        let scene: SavedScene
        let generatedEnvironmentEXR: Data?
        let outputPlan: RenderOutputPlan
        let configuration: StudioResolvedRenderConfiguration
        var destination: URL { outputPlan.destination }
        var state: State = .pending
        var progress = 0.0
        var detail = "Pendiente"
        var terminalTiming: TerminalTiming?

        init(
            id: UUID = UUID(), derivedFromJobID: UUID? = nil,
            scene: SavedScene, generatedEnvironmentEXR: Data?,
            outputPlan: RenderOutputPlan, configuration: StudioResolvedRenderConfiguration,
            state: State = .pending, progress: Double = 0, detail: String = "Pendiente",
            terminalTiming: TerminalTiming? = nil
        ) {
            self.id = id
            self.derivedFromJobID = derivedFromJobID
            self.scene = scene
            self.generatedEnvironmentEXR = generatedEnvironmentEXR
            self.outputPlan = outputPlan
            self.configuration = configuration
            self.state = state
            self.progress = progress
            self.detail = detail
            self.terminalTiming = terminalTiming
        }
    }

    typealias Progress = @MainActor (_ completed: Int, _ total: Int) -> Void
    typealias AttemptPreflight = @MainActor (
        _ job: RenderJob
    ) throws -> StudioOverwritePolicy?
    typealias RenderOperation = @MainActor (
        _ job: RenderJob,
        _ progress: @escaping Progress
    ) async throws -> URL

    @Published private(set) var jobs: [RenderJob]
    @Published private(set) var isPaused: Bool
    @Published private(set) var persistenceError: String?
    @Published private(set) var activeTiming: [UUID: RenderTiming] = [:]
    private let store: RenderQueueStore?
    private var activeTask: Task<Void, Never>?
    private var timingTask: Task<Void, Never>?
    private var activeStartedAt: ContinuousClock.Instant?
    private var activePreviousFrameAt: ContinuousClock.Instant?
    private var activeLastFrameSeconds: TimeInterval?
    private var activeCompletedFrames = 0
    private var activeTotalFrames = 0

    init(store: RenderQueueStore) throws {
        self.store = store
        let document = try store.load()
        var resumedInterruptedJob = false
        jobs = document.jobs.map { job in
            guard job.state == .rendering else { return job }
            resumedInterruptedJob = true
            return RenderJob(
                id: job.id, derivedFromJobID: job.derivedFromJobID, scene: job.scene,
                generatedEnvironmentEXR: job.generatedEnvironmentEXR,
                outputPlan: job.outputPlan, configuration: job.configuration,
                state: .pending, progress: 0,
                detail: "Interrumpido al cerrar la aplicación", terminalTiming: nil
            )
        }
        isPaused = document.isPaused
        persistenceError = nil
        if resumedInterruptedJob { persist() }
    }

    init(rejectedStoreError message: String) {
        store = nil
        jobs = []
        isPaused = true
        persistenceError = message
    }

    var hasPendingJobs: Bool { jobs.contains { $0.state == .pending } }
    var isRendering: Bool { activeTask != nil }

    func enqueue(
        scene: SavedScene,
        generatedEnvironmentEXR: Data?,
        outputPlan: RenderOutputPlan,
        configuration: StudioResolvedRenderConfiguration,
        derivedFromJobID: UUID? = nil
    ) {
        guard persistenceError == nil else { return }
        jobs.append(RenderJob(
            derivedFromJobID: derivedFromJobID, scene: scene,
            generatedEnvironmentEXR: generatedEnvironmentEXR,
            outputPlan: outputPlan,
            configuration: configuration
        ))
        persist()
    }

    func run(
        preflight: @escaping AttemptPreflight = { $0.configuration.overwritePolicy },
        operation: @escaping RenderOperation,
        onFailure: @escaping @MainActor (String) -> Void
    ) {
        guard persistenceError == nil, !isPaused, activeTask == nil,
              let index = jobs.firstIndex(where: { $0.state == .pending })
        else { return }
        do {
            let pending = jobs[index]
            guard let overwritePolicy = try preflight(pending) else { return }
            if overwritePolicy != pending.configuration.overwritePolicy {
                jobs[index] = RenderJob(
                    id: pending.id, derivedFromJobID: pending.derivedFromJobID,
                    scene: pending.scene,
                    generatedEnvironmentEXR: pending.generatedEnvironmentEXR,
                    outputPlan: pending.outputPlan,
                    configuration: pending.configuration.replacingOverwritePolicy(
                        overwritePolicy
                    ),
                    state: pending.state, progress: pending.progress,
                    detail: pending.detail, terminalTiming: pending.terminalTiming
                )
                persist()
            }
        } catch {
            jobs[index].detail = "Preflight: \(error.localizedDescription)"
            persist()
            onFailure(error.localizedDescription)
            return
        }
        jobs[index].state = .rendering
        jobs[index].detail = "Preparando salida"
        persist()
        let job = jobs[index]
        beginTiming(jobID: job.id)
        activeTask = Task {
            do {
                let url = try await operation(job) { [weak self] completed, total in
                    guard let self,
                          total > 0,
                          let live = self.jobs.firstIndex(where: { $0.id == job.id })
                    else { return }
                    self.jobs[live].progress = min(1, max(0, Double(completed) / Double(total)))
                    self.jobs[live].detail = "Frame \(completed) / \(total)"
                    let now = ContinuousClock.now
                    if let previous = self.activePreviousFrameAt {
                        self.activeLastFrameSeconds = previous.duration(to: now).secondsMagnitude
                    }
                    self.activePreviousFrameAt = now
                    self.activeCompletedFrames = completed
                    self.activeTotalFrames = total
                    self.publishTiming(jobID: job.id)
                    self.persist()
                }
                let terminalTiming = endTiming(jobID: job.id)
                if let live = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[live].state = .completed
                    jobs[live].progress = 1
                    jobs[live].detail = url.lastPathComponent
                    jobs[live].terminalTiming = terminalTiming
                    persist()
                }
            } catch is CancellationError {
                let terminalTiming = endTiming(jobID: job.id)
                if let live = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[live].state = .cancelled
                    jobs[live].detail = "Cancelado"
                    jobs[live].terminalTiming = terminalTiming
                    persist()
                }
            } catch {
                let terminalTiming = endTiming(jobID: job.id)
                if let live = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[live].state = .failed
                    jobs[live].detail = error.localizedDescription
                    jobs[live].terminalTiming = terminalTiming
                    persist()
                }
                onFailure(error.localizedDescription)
            }
            activeTask = nil
            run(preflight: preflight, operation: operation, onFailure: onFailure)
        }
    }

    func cancel() {
        activeTask?.cancel()
    }

    func timing(for jobID: UUID) -> RenderTiming? {
        activeTiming[jobID]
    }

    func pause() {
        isPaused = true
        persist()
    }

    func resume() {
        guard persistenceError == nil else { return }
        isPaused = false
        persist()
    }

    func clearTerminalJobs() {
        jobs.removeAll { $0.state.isTerminal }
        persist()
    }

    /// Removes one inactive queue record. It never deletes scene data or generated output.
    @discardableResult
    func removeInactiveJob(id: RenderJob.ID) -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].state != .rendering
        else { return false }
        jobs.remove(at: index)
        persist()
        return true
    }

    private func persist() {
        guard let store else { return }
        do {
            try store.save(.init(isPaused: isPaused, jobs: jobs))
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
        }
    }

    private func beginTiming(jobID: UUID) {
        timingTask?.cancel()
        activeStartedAt = .now
        activePreviousFrameAt = activeStartedAt
        activeLastFrameSeconds = nil
        activeCompletedFrames = 0
        activeTotalFrames = 0
        publishTiming(jobID: jobID)
        timingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.publishTiming(jobID: jobID)
            }
        }
    }

    private func publishTiming(jobID: UUID) {
        guard let activeStartedAt else { return }
        let elapsed = max(0, activeStartedAt.duration(to: .now).secondsMagnitude)
        let remaining: TimeInterval?
        if activeCompletedFrames > 0, activeTotalFrames >= activeCompletedFrames {
            remaining = elapsed * Double(activeTotalFrames - activeCompletedFrames)
                / Double(activeCompletedFrames)
        } else {
            remaining = nil
        }
        activeTiming[jobID] = RenderTiming(
            elapsedSeconds: elapsed,
            approximateRemainingSeconds: remaining,
            lastCompletedFrameSeconds: activeLastFrameSeconds,
            averageCompletedFrameSeconds: activeCompletedFrames > 0
                ? elapsed / Double(activeCompletedFrames) : nil
        )
    }

    private func endTiming(jobID: UUID) -> TerminalTiming? {
        guard let activeStartedAt else { return nil }
        let elapsed = max(0, activeStartedAt.duration(to: .now).secondsMagnitude)
        let result = TerminalTiming(
            totalSeconds: elapsed,
            averageCompletedFrameSeconds: activeCompletedFrames > 0
                ? elapsed / Double(activeCompletedFrames) : nil
        )
        timingTask?.cancel()
        timingTask = nil
        self.activeStartedAt = nil
        activePreviousFrameAt = nil
        activeLastFrameSeconds = nil
        activeTiming.removeValue(forKey: jobID)
        return result
    }
}

private extension Duration {
    var secondsMagnitude: TimeInterval {
        let components = self.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
