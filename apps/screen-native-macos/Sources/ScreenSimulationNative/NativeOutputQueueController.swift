import Foundation
import StudioMedia

@MainActor
final class NativeOutputQueueController: ObservableObject {
    struct RenderTiming: Equatable, Sendable {
        let elapsedSeconds: TimeInterval
        let approximateRemainingSeconds: TimeInterval?
    }

    struct RenderJob: Codable, Identifiable {
        enum State: String, Codable { case pending, rendering, completed, failed, cancelled }
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

        init(
            id: UUID = UUID(), derivedFromJobID: UUID? = nil,
            scene: SavedScene, generatedEnvironmentEXR: Data?,
            outputPlan: RenderOutputPlan, configuration: StudioResolvedRenderConfiguration,
            state: State = .pending, progress: Double = 0, detail: String = "Pendiente"
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
        }
    }

    typealias Progress = @MainActor (_ completed: Int, _ total: Int) -> Void
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
                detail: "Interrumpido al cerrar la aplicación"
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
        operation: @escaping RenderOperation,
        onFailure: @escaping @MainActor (String) -> Void
    ) {
        guard persistenceError == nil, !isPaused, activeTask == nil,
              let index = jobs.firstIndex(where: { $0.state == .pending })
        else { return }
        jobs[index].state = .rendering
        jobs[index].detail = "Preparando grafo Metal"
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
                    self.jobs[live].detail = "\(completed) / \(total)"
                    self.activeCompletedFrames = completed
                    self.activeTotalFrames = total
                    self.publishTiming(jobID: job.id)
                    self.persist()
                }
                if let live = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[live].state = .completed
                    jobs[live].progress = 1
                    jobs[live].detail = url.lastPathComponent
                    persist()
                }
            } catch is CancellationError {
                if let live = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[live].state = .cancelled
                    jobs[live].detail = "Cancelado"
                    persist()
                }
            } catch {
                if let live = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[live].state = .failed
                    jobs[live].detail = error.localizedDescription
                    persist()
                }
                onFailure(error.localizedDescription)
            }
            endTiming(jobID: job.id)
            activeTask = nil
            run(operation: operation, onFailure: onFailure)
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
        jobs.removeAll { ![.pending, .rendering].contains($0.state) }
        persist()
    }

    /// Removes one inactive queue record. It never deletes scene data or generated output.
    @discardableResult
    func removeInactiveJob(id: RenderJob.ID) -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              [.pending, .failed, .completed].contains(jobs[index].state)
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
            approximateRemainingSeconds: remaining
        )
    }

    private func endTiming(jobID: UUID) {
        timingTask?.cancel()
        timingTask = nil
        activeStartedAt = nil
        activeTiming.removeValue(forKey: jobID)
    }
}

private extension Duration {
    var secondsMagnitude: TimeInterval {
        let components = self.components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
