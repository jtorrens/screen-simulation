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
    static let schema = "ScreenSimulation.RenderQueue.v8"

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
            let expectedKind: RenderOutputPlan.Kind
            if job.configuration.outputType == .fusionScenePackage {
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
        documentURL = directory.appendingPathComponent("RenderQueue.v8.json")
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
            "id", "derivedFromJobID", "scene", "generatedEnvironmentEXR", "outputPlan", "configuration",
            "state", "progress", "detail",
        ]
        let keysWithoutEnvironment = expectedJobKeys.subtracting(["generatedEnvironmentEXR"])
        let keysWithoutDerived = expectedJobKeys.subtracting(["derivedFromJobID"])
        let keysWithoutOptional = expectedJobKeys.subtracting([
            "generatedEnvironmentEXR", "derivedFromJobID",
        ])
        guard jobs.allSatisfy({
            let keys = Set($0.keys)
            return keys == expectedJobKeys || keys == keysWithoutEnvironment
                || keys == keysWithoutDerived || keys == keysWithoutOptional
        }) else {
            throw RenderQueueStoreError.invalidDocument("Un trabajo de Render Queue contiene campos desconocidos.")
        }
        let requiredConfigurationKeys: Set<String> = [
            "outputType", "jobName", "overwritePolicy", "composition",
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
