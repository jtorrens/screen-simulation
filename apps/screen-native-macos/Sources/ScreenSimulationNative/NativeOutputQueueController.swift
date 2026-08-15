import Foundation
import StudioMedia

@MainActor
final class NativeOutputQueueController: ObservableObject {
    struct RenderJob: Identifiable {
        enum State: String { case pending, rendering, completed, failed, cancelled }
        let id = UUID()
        let scene: SavedScene
        let generatedEnvironmentEXR: Data?
        let destination: URL
        let configuration: StudioResolvedRenderConfiguration
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
        destination: URL,
        configuration: StudioResolvedRenderConfiguration
    ) {
        jobs.append(RenderJob(
            scene: scene,
            generatedEnvironmentEXR: generatedEnvironmentEXR,
            destination: destination,
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
}
