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
    static let schema = "ScreenSimulation.RenderQueue.v14"

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
            guard job.derivedFromJobID != job.id else {
                throw RenderQueueStoreError.invalidDocument("Un render no puede derivar de sí mismo.")
            }
            guard !job.outputPlan.destination.path.isEmpty,
                  !job.outputPlan.generatedRelativePaths.isEmpty,
                  job.progress.isFinite,
                  (0 ... 1).contains(job.progress),
                  !job.detail.isEmpty else {
                throw RenderQueueStoreError.invalidDocument("Un trabajo persistido de Render Queue no es válido.")
            }
            if let timing = job.terminalTiming {
                guard job.state.isTerminal,
                      timing.totalSeconds.isFinite, timing.totalSeconds >= 0,
                      timing.averageCompletedFrameSeconds.map({ $0.isFinite && $0 >= 0 }) ?? true
                else {
                    throw RenderQueueStoreError.invalidDocument(
                        "Los tiempos finales de Render Queue no son válidos."
                    )
                }
            } else if job.state.isTerminal {
                throw RenderQueueStoreError.invalidDocument(
                    "Un trabajo terminal de Render Queue no contiene sus tiempos finales."
                )
            }
            let expectedKind: RenderOutputPlan.Kind
            if job.configuration.fusionScene != nil {
                expectedKind = .fusionScenePackage
            } else if job.configuration.composition == .deviceAndSpillSeparate {
                expectedKind = .deviceSpillDelivery
            } else {
                expectedKind = job.configuration.format.isMovie ? .singleFile : .imageSequence
            }
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
        documentURL = directory.appendingPathComponent("RenderQueue.v14.json")
    }

    func load() throws -> RenderQueueDocument {
        guard FileManager.default.fileExists(atPath: documentURL.path) else {
            let prior = directoryURL.appendingPathComponent("RenderQueue.v13.json")
            if FileManager.default.fileExists(atPath: prior.path) {
                throw RenderQueueStoreError.invalidDocument(
                    "Existe RenderQueue.v13.json. Elimina la cola histórica antes de abrir el contrato v14."
                )
            }
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
            "id", "derivedFromJobID", "scene", "generatedEnvironmentEXR", "outputPlan", "configuration",
            "state", "progress", "detail", "terminalTiming",
        ]
        let requiredJobKeys = expectedJobKeys.subtracting([
            "generatedEnvironmentEXR", "derivedFromJobID", "terminalTiming",
        ])
        guard jobs.allSatisfy({
            let keys = Set($0.keys)
            return requiredJobKeys.isSubset(of: keys) && keys.isSubset(of: expectedJobKeys)
        }) else {
            throw RenderQueueStoreError.invalidDocument("Un trabajo de Render Queue contiene campos desconocidos.")
        }
        guard jobs.allSatisfy({ job in
            guard let timing = job["terminalTiming"] else { return true }
            guard let object = timing as? [String: Any] else { return false }
            let required: Set<String> = ["totalSeconds"]
            let allowed: Set<String> = ["totalSeconds", "averageCompletedFrameSeconds"]
            let keys = Set(object.keys)
            return required.isSubset(of: keys) && keys.isSubset(of: allowed)
        }) else {
            throw RenderQueueStoreError.invalidDocument(
                "Los tiempos finales de Render Queue contienen campos desconocidos."
            )
        }
        let requiredConfigurationKeys: Set<String> = [
            "renderMode", "jobName", "versionSuffix", "overwritePolicy", "composition",
            "spillDeliveryMode", "motionBlurMode", "motionSamples", "format", "pipeline", "target",
            "raster", "peakNits", "pixelEncoding", "signalRange", "alpha", "includeAudio",
            "frameRate", "firstFrame", "lastFrame",
        ]
        let optionalConfigurationKeys: Set<String> = [
            "fusionScene", "display", "view", "vfxInterchangeEncodingID", "wipReview",
        ]
        guard jobs.allSatisfy({ job in
            guard let configuration = job["configuration"] as? [String: Any] else {
                return false
            }
            let keys = Set(configuration.keys)
            guard requiredConfigurationKeys.isSubset(of: keys),
                  let raster = configuration["raster"] as? [String: Any],
                  Set(raster.keys) == ["width", "height", "placementID"] else { return false }
            return keys.isSubset(of: requiredConfigurationKeys.union(optionalConfigurationKeys))
        }) else {
            throw RenderQueueStoreError.invalidDocument(
                "La configuración persistida de Render Queue no pertenece al contrato vigente."
            )
        }
    }
}
