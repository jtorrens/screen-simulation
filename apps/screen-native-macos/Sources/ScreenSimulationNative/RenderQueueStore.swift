import Foundation
import StudioMedia

enum RenderQueueStoreError: LocalizedError {
    case invalidDocument(String)

    var errorDescription: String? {
        switch self {
        case let .invalidDocument(message): message
        }
    }
}

struct RenderQueueDocument: Codable {
    static let schema = "ScreenSimulation.RenderQueue.v2"

    let schema: String
    let isPaused: Bool
    let jobs: [NativeOutputQueueController.RenderJob]

    init(isPaused: Bool = false, jobs: [NativeOutputQueueController.RenderJob] = []) {
        schema = Self.schema
        self.isPaused = isPaused
        self.jobs = jobs
    }

    func validate() throws {
        guard schema == Self.schema,
              Set(jobs.map(\.id)).count == jobs.count else {
            throw RenderQueueStoreError.invalidDocument("El documento persistido de Render Queue no es válido.")
        }
        for job in jobs {
            try job.scene.validate()
            try job.configuration.validate()
            guard !job.outputPlan.destination.path.isEmpty,
                  !job.outputPlan.generatedRelativePaths.isEmpty,
                  job.progress.isFinite,
                  (0 ... 1).contains(job.progress),
                  !job.detail.isEmpty else {
                throw RenderQueueStoreError.invalidDocument("Un trabajo persistido de Render Queue no es válido.")
            }
            let expectedKind: RenderOutputPlan.Kind = job.configuration.outputType == .fusionScenePackage
                ? .fusionScenePackage
                : (job.configuration.format.isMovie ? .singleFile : .imageSequence)
            guard job.outputPlan.kind == expectedKind else {
                throw RenderQueueStoreError.invalidDocument("El destino persistido no corresponde al tipo de render.")
            }
        }
    }
}

struct RenderQueueStore: Sendable {
    let directoryURL: URL
    let documentURL: URL

    init(directoryURL: URL? = nil) throws {
        let directory: URL
        if let directoryURL {
            directory = directoryURL
        } else {
            let root = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            directory = root.appendingPathComponent(
                "SCREEN-SIMULATION/RenderQueue", isDirectory: true
            )
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directoryURL = directory
        documentURL = directory.appendingPathComponent("RenderQueue.v2.json")
    }

    func load() throws -> RenderQueueDocument {
        guard FileManager.default.fileExists(atPath: documentURL.path) else {
            return RenderQueueDocument()
        }
        let data = try Data(contentsOf: documentURL)
        try validateStrictShape(data)
        let document = try JSONDecoder().decode(RenderQueueDocument.self, from: data)
        try document.validate()
        return document
    }

    func save(_ document: RenderQueueDocument) throws {
        try document.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(document).write(to: documentURL, options: .atomic)
    }

    private func validateStrictShape(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == ["schema", "isPaused", "jobs"],
              let jobs = root["jobs"] as? [[String: Any]] else {
            throw RenderQueueStoreError.invalidDocument("El contrato de Render Queue es desconocido.")
        }
        let expectedJobKeys: Set<String> = [
            "id", "scene", "generatedEnvironmentEXR", "outputPlan", "configuration",
            "state", "progress", "detail",
        ]
        let keysWithoutEnvironment = expectedJobKeys.subtracting(["generatedEnvironmentEXR"])
        guard jobs.allSatisfy({
            Set($0.keys) == expectedJobKeys || Set($0.keys) == keysWithoutEnvironment
        }) else {
            throw RenderQueueStoreError.invalidDocument("Un trabajo de Render Queue contiene campos desconocidos.")
        }
    }
}
