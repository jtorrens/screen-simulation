import Foundation
import StudioMedia

@MainActor
final class NativeOutputQueueController: ObservableObject {
    struct RenderJob: Identifiable {
        enum State: String { case pending, rendering, completed, failed, cancelled }
        let id = UUID()
        let scene: SavedScene
        let generatedEnvironmentEXR: Data?
        let outputPlan: RenderOutputPlan
        let configuration: StudioResolvedRenderConfiguration
        var destination: URL { outputPlan.destination }
        var state: State = .pending
        var progress = 0.0
        var detail = "Pendiente"
    }

    typealias Progress = @MainActor (_ completed: Int, _ total: Int) -> Void
    typealias RenderOperation = @MainActor (
        _ job: RenderJob,
        _ progress: @escaping Progress
    ) async throws -> URL

    @Published private(set) var jobs: [RenderJob] = []
    private var activeTask: Task<Void, Never>?

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
    }

    func run(
        operation: @escaping RenderOperation,
        onFailure: @escaping @MainActor (String) -> Void
    ) {
        guard activeTask == nil,
              let index = jobs.firstIndex(where: { $0.state == .pending })
        else { return }
        jobs[index].state = .rendering
        jobs[index].detail = "Preparando grafo Metal"
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
                }
                if let live = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[live].state = .completed
                    jobs[live].progress = 1
                    jobs[live].detail = url.lastPathComponent
                }
            } catch is CancellationError {
                if let live = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[live].state = .cancelled
                    jobs[live].detail = "Cancelado"
                }
            } catch {
                if let live = jobs.firstIndex(where: { $0.id == job.id }) {
                    jobs[live].state = .failed
                    jobs[live].detail = error.localizedDescription
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
        return true
    }
}
