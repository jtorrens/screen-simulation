import Foundation
import StudioMedia

@MainActor
final class NativeOutputQueueController: ObservableObject {
    struct RenderJob: Codable, Identifiable {
        enum State: String, Codable { case pending, rendering, completed, failed, cancelled }
        let id: UUID
        let scene: SavedScene
        let generatedEnvironmentEXR: Data?
        let outputPlan: RenderOutputPlan
        let configuration: StudioResolvedRenderConfiguration
        var destination: URL { outputPlan.destination }
        var state: State = .pending
        var progress = 0.0
        var detail = "Pendiente"

        init(
            id: UUID = UUID(), scene: SavedScene, generatedEnvironmentEXR: Data?,
            outputPlan: RenderOutputPlan, configuration: StudioResolvedRenderConfiguration,
            state: State = .pending, progress: Double = 0, detail: String = "Pendiente"
        ) {
            self.id = id
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
    private let store: RenderQueueStore
    private var activeTask: Task<Void, Never>?

    init(store: RenderQueueStore) throws {
        self.store = store
        let document = try store.load()
        var resumedInterruptedJob = false
        jobs = document.jobs.map { job in
            guard job.state == .rendering else { return job }
            resumedInterruptedJob = true
            return RenderJob(
                id: job.id, scene: job.scene,
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

    var hasPendingJobs: Bool { jobs.contains { $0.state == .pending } }
    var isRendering: Bool { activeTask != nil }

    func enqueue(
        scene: SavedScene,
        generatedEnvironmentEXR: Data?,
        outputPlan: RenderOutputPlan,
        configuration: StudioResolvedRenderConfiguration
    ) {
        jobs.append(RenderJob(
            scene: scene,
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
        guard !isPaused, activeTask == nil,
              let index = jobs.firstIndex(where: { $0.state == .pending })
        else { return }
        jobs[index].state = .rendering
        jobs[index].detail = "Preparando grafo Metal"
        persist()
        let job = jobs[index]
        activeTask = Task {
            do {
                let url = try await operation(job) { [weak self] completed, total in
                    guard let self,
                          total > 0,
                          let live = self.jobs.firstIndex(where: { $0.id == job.id })
                    else { return }
                    self.jobs[live].progress = min(1, max(0, Double(completed) / Double(total)))
                    self.jobs[live].detail = "\(completed) / \(total)"
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
            activeTask = nil
            run(operation: operation, onFailure: onFailure)
        }
    }

    func cancel() {
        activeTask?.cancel()
    }

    func pause() {
        isPaused = true
        persist()
    }

    func resume() {
        isPaused = false
        persist()
    }

    func clearCompleted() {
        jobs.removeAll { $0.state == .completed }
        persist()
    }

    /// Reopens only a terminal successful job. Its immutable scene snapshot and resolved
    /// output configuration remain unchanged, so a later edit to the live workspace can
    /// never redirect a queued render.
    @discardableResult
    func requeueCompletedJob(id: RenderJob.ID) -> Bool {
        guard let index = jobs.firstIndex(where: { $0.id == id }),
              jobs[index].state == .completed
        else { return false }
        jobs[index].state = .pending
        jobs[index].progress = 0
        jobs[index].detail = "Pendiente"
        persist()
        return true
    }

    private func persist() {
        do {
            try store.save(.init(isPaused: isPaused, jobs: jobs))
            persistenceError = nil
        } catch {
            persistenceError = error.localizedDescription
        }
    }
}
