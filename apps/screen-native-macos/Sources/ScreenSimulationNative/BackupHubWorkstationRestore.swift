import AppKit
import CryptoKit
import Darwin
import Foundation

enum WorkstationRestoreState: String, Codable {
    case applied, cancelled, rejected, failed
}

enum WorkstationRestoreDecision: String, Codable {
    case confirmed, cancelled
    case notPresented = "not-presented"
}

enum WorkstationRestoreErrorCode: String, Codable {
    case requestInvalid = "request-invalid"
    case identityMismatch = "identity-mismatch"
    case contractMismatch = "contract-mismatch"
    case manifestHashMismatch = "manifest-hash-mismatch"
    case payloadIncomplete = "payload-incomplete"
    case payloadHashMismatch = "payload-hash-mismatch"
    case snapshotInvalid = "snapshot-invalid"
    case confirmationFailed = "confirmation-failed"
    case preRestoreBackupFailed = "pre-restore-backup-failed"
    case replacementFailed = "replacement-failed"
    case verificationFailed = "verification-failed"
    case postPreRestoreInternalError = "post-pre-restore-internal-error"
}

struct WorkstationRestoreSummary: Codable, Equatable {
    let createdAt: String
    let reason: String
    let snapshotFormat: String
    let snapshotSchemaVersion: String
    let fileCount: Int
    let totalBytes: Int
}

struct WorkstationRestoreConfirmation {
    let requestID: UUID
    let packageID: UUID
    let summary: WorkstationRestoreSummary
}

struct WorkstationRestoreRecord {
    let requestID: UUID
    let packageID: UUID?
    let preRestorePackageID: UUID?
    let state: WorkstationRestoreState
    let errorCode: WorkstationRestoreErrorCode?
    let errorMessage: String?
}

enum WorkstationRestoreConsumerError: LocalizedError {
    case invalidOwnerProtocolMarker
    case ownerProtocolCutoverCollision
    case invalidRecoveryState
    case resultAlreadyExists
    case quarantineCollision
    case atomicSwapFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidOwnerProtocolMarker:
            "El marcador propietario de restore no contiene exactamente la versión 2."
        case .ownerProtocolCutoverCollision:
            "Existen simultáneamente restore-processing y su retiro v1 para SCREEN-SIMULATION."
        case .invalidRecoveryState:
            "La transacción de restore interrumpida no tiene un estado recuperable."
        case .resultAlreadyExists:
            "Ya existe un resultado terminal para esta restauración."
        case .quarantineCollision:
            "Ya existe evidencia en cuarentena para esta restauración."
        case let .atomicSwapFailed(code):
            "El intercambio atómico del estado falló (errno \(code))."
        }
    }
}

struct BackupHubWorkstationRestoreConsumer {
    static let handoffVersion = 2
    static let applicationID = "screen-simulation"

    private let applicationSupportURL: URL
    private let producerVersion: () throws -> String
    private let makePreRestorePackageID: () -> UUID
    private let now: () -> Date
    private let fileManager: FileManager

    init(
        applicationSupportURL: URL? = nil,
        producerVersion: @escaping () throws -> String = {
            guard let value = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String,
            !value.isEmpty else {
                throw WorkstationBackupError.publicationFailed(
                    "la aplicación instalada no declara CFBundleShortVersionString"
                )
            }
            return value
        },
        makePreRestorePackageID: @escaping () -> UUID = UUID.init,
        now: @escaping () -> Date = Date.init,
        fileManager: FileManager = .default
    ) throws {
        if let applicationSupportURL {
            self.applicationSupportURL = applicationSupportURL
        } else {
            self.applicationSupportURL = try fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
        }
        self.producerVersion = producerVersion
        self.makePreRestorePackageID = makePreRestorePackageID
        self.now = now
        self.fileManager = fileManager
    }

    func processPendingRestores(
        confirmation: (WorkstationRestoreConfirmation) throws -> WorkstationRestoreDecision
    ) throws -> [WorkstationRestoreRecord] {
        let producer = try BackupHubWorkstationProducer(
            applicationSupportURL: applicationSupportURL,
            producerVersion: producerVersion,
            makePackageID: makePreRestorePackageID,
            now: now,
            fileManager: fileManager
        )
        let vault = try producer.validatedVaultURL()
        let locations = RestoreLocations(vault: vault)
        try locations.prepareOwnership(fileManager: fileManager)
        try claimPreparedRequests(locations: locations)

        var records: [WorkstationRestoreRecord] = []
        for claimed in try restoreDirectories(at: locations.processing) {
            let requestID = try requestID(from: claimed)
            let resultURL = locations.resultURL(requestID)
            try recoverTransaction(
                requestID: requestID,
                resultExists: fileManager.fileExists(atPath: resultURL.path)
            )
            if fileManager.fileExists(atPath: resultURL.path) {
                try finalizeExistingResult(
                    at: resultURL, claimed: claimed, locations: locations
                )
                continue
            }
            let record = try process(
                claimed: claimed,
                requestID: requestID,
                locations: locations,
                producer: producer,
                confirmation: confirmation
            )
            records.append(record)
        }
        return records
    }

    private func process(
        claimed: URL,
        requestID: UUID,
        locations: RestoreLocations,
        producer: BackupHubWorkstationProducer,
        confirmation: (WorkstationRestoreConfirmation) throws -> WorkstationRestoreDecision
    ) throws -> WorkstationRestoreRecord {
        let request: RestoreRequestV2
        do {
            request = try decodeRequest(
                at: claimed.appendingPathComponent("request.json"),
                directoryRequestID: requestID
            )
        } catch {
            return try publishTerminal(
                .requestInvalid(requestID: requestID, date: now(), message: error.localizedDescription),
                claimed: claimed,
                locations: locations
            )
        }

        let package = claimed.appendingPathComponent("package", isDirectory: true)
        do {
            try validateHandoff(
                request: request,
                requestID: requestID,
                package: package,
                producer: producer,
                claimed: claimed
            )
        } catch let failure as RestoreFailure {
            return try publishTerminal(
                .rejected(
                    request: request, requestID: requestID, date: now(),
                    code: failure.code, message: failure.message
                ),
                claimed: claimed,
                locations: locations
            )
        } catch {
            return try publishTerminal(
                .rejected(
                    request: request, requestID: requestID, date: now(),
                    code: .snapshotInvalid, message: error.localizedDescription
                ),
                claimed: claimed,
                locations: locations
            )
        }

        let decision: WorkstationRestoreDecision
        do {
            decision = try confirmation(.init(
                requestID: requestID,
                packageID: request.packageId,
                summary: request.backupSummary
            ))
        } catch {
            return try publishTerminal(
                .failed(
                    request: request, requestID: requestID, date: now(),
                    decision: .notPresented, code: .confirmationFailed,
                    message: error.localizedDescription
                ),
                claimed: claimed,
                locations: locations
            )
        }
        if decision == .cancelled {
            return try publishTerminal(
                .cancelled(request: request, requestID: requestID, date: now()),
                claimed: claimed,
                locations: locations
            )
        }

        let preRestore: PublishedWorkstationBackup
        do {
            preRestore = try producer.publishPackage(reason: .preRestore)
            guard preRestore.packageID != request.packageId else {
                throw WorkstationBackupError.publicationFailed(
                    "pre-restore reutilizó la identidad del backup seleccionado"
                )
            }
        } catch {
            return try publishTerminal(
                .failed(
                    request: request, requestID: requestID, date: now(),
                    decision: .confirmed, code: .preRestoreBackupFailed,
                    message: error.localizedDescription
                ),
                claimed: claimed,
                locations: locations
            )
        }

        do {
            try replaceLiveState(
                requestID: requestID,
                package: package,
                preRestorePackageID: preRestore.packageID
            )
        } catch let failure as RestoreFailure {
            return try publishTerminal(
                .failed(
                    request: request, requestID: requestID, date: now(),
                    decision: .confirmed, preRestorePackageID: preRestore.packageID,
                    code: failure.code, message: failure.message
                ),
                claimed: claimed,
                locations: locations
            )
        } catch {
            return try publishTerminal(
                .failed(
                    request: request, requestID: requestID, date: now(),
                    decision: .confirmed, preRestorePackageID: preRestore.packageID,
                    code: .postPreRestoreInternalError, message: error.localizedDescription
                ),
                claimed: claimed,
                locations: locations
            )
        }

        let result = RestoreResultV2.applied(
            request: request,
            requestID: requestID,
            preRestorePackageID: preRestore.packageID,
            date: now()
        )
        do {
            let record = try publishTerminal(
                result,
                claimed: claimed,
                locations: locations,
                deferClaimFinalization: true
            )
            try commitTransaction(requestID: requestID)
            try fileManager.removeItem(at: claimed)
            return record
        } catch {
            throw error
        }
    }

    private func validateHandoff(
        request: RestoreRequestV2,
        requestID: UUID,
        package: URL,
        producer: BackupHubWorkstationProducer,
        claimed: URL
    ) throws {
        guard request.requestId == requestID,
              request.applicationId == Self.applicationID else {
            throw RestoreFailure(
                .identityMismatch,
                "La solicitud no pertenece a SCREEN-SIMULATION o su identidad no coincide."
            )
        }
        guard request.handoffVersion == Self.handoffVersion,
              request.state == "prepared",
              isRFC3339(request.preparedAt),
              isLowercaseSHA256(request.vaultObjectSha256) else {
            throw RestoreFailure(.contractMismatch, "La solicitud no cumple Restore Handoff v2.")
        }
        let manifestURL = package.appendingPathComponent("manifest.json")
        let manifestData: Data
        do { manifestData = try Data(contentsOf: manifestURL) }
        catch { throw RestoreFailure(.payloadIncomplete, "Falta manifest.json.") }
        guard sha256(manifestData) == request.manifestSha256 else {
            throw RestoreFailure(.manifestHashMismatch, "El hash de manifest.json no coincide.")
        }

        let manifest: BackupPackageManifest
        do {
            manifest = try producer.validatedRestoreManifest(
                at: package,
                expectedPackageID: request.packageId
            )
        } catch {
            let raw = try? JSONDecoder().decode(BackupPackageManifest.self, from: manifestData)
            if raw?.applicationId != Self.applicationID || raw?.packageId.lowercased()
                != request.packageId.uuidString.lowercased() {
                throw RestoreFailure(.identityMismatch, error.localizedDescription)
            }
            let actual = try? producer.payloadFiles(
                at: package.appendingPathComponent("payload")
            )
            if let raw, let actual,
               Set(raw.files.map(\.path)) != Set(actual.map(\.path)) {
                throw RestoreFailure(.payloadIncomplete, error.localizedDescription)
            }
            if let raw, let actual, raw.files != actual {
                throw RestoreFailure(.payloadHashMismatch, error.localizedDescription)
            }
            throw RestoreFailure(.contractMismatch, error.localizedDescription)
        }

        let total = manifest.files.reduce(into: 0) { $0 += $1.byteLength }
        let derived = WorkstationRestoreSummary(
            createdAt: manifest.createdAt,
            reason: manifest.reason,
            snapshotFormat: manifest.snapshot.format,
            snapshotSchemaVersion: manifest.snapshot.schemaVersion,
            fileCount: manifest.files.count,
            totalBytes: total
        )
        guard request.backupSummary == derived else {
            throw RestoreFailure(.contractMismatch, "backupSummary no coincide con el manifest verificado.")
        }

        let validation = claimed.appendingPathComponent(".snapshot-validation", isDirectory: true)
        if fileManager.fileExists(atPath: validation.path) {
            try fileManager.removeItem(at: validation)
        }
        defer { try? fileManager.removeItem(at: validation) }
        let validationState = validation.appendingPathComponent("SCREEN-SIMULATION", isDirectory: true)
        try materializeSnapshot(
            package.appendingPathComponent("payload/state", isDirectory: true),
            at: validationState
        )
        do {
            try validateState(
                applicationSupportRoot: validation,
                descriptorURL: package.appendingPathComponent("payload/snapshot.json")
            )
        } catch {
            throw RestoreFailure(.snapshotInvalid, error.localizedDescription)
        }
    }

    private func replaceLiveState(
        requestID: UUID,
        package: URL,
        preRestorePackageID: UUID
    ) throws {
        let transaction = transactionURL(requestID)
        guard !fileManager.fileExists(atPath: transaction.path) else {
            throw RestoreFailure(.replacementFailed, "Ya existe una transacción para esta solicitud.")
        }
        let candidate = transaction.appendingPathComponent("SCREEN-SIMULATION", isDirectory: true)
        let live = liveStateURL
        do {
            try fileManager.createDirectory(at: transaction, withIntermediateDirectories: false)
            if fileManager.fileExists(atPath: live.path) {
                try fileManager.copyItem(at: live, to: candidate)
            } else {
                try fileManager.createDirectory(at: candidate, withIntermediateDirectories: false)
                try fileManager.createDirectory(at: live, withIntermediateDirectories: false)
            }
            try removeCurrentManagedState(from: candidate)
            try materializeSnapshot(
                package.appendingPathComponent("payload/state", isDirectory: true),
                at: candidate
            )
            try validateState(
                applicationSupportRoot: transaction,
                descriptorURL: package.appendingPathComponent("payload/snapshot.json")
            )
            let journal = RestoreJournal(
                requestId: requestID,
                preRestorePackageId: preRestorePackageID,
                previousHash: try managedStateHash(live),
                candidateHash: try managedStateHash(candidate)
            )
            try encode(journal).write(
                to: transaction.appendingPathComponent("journal.json"), options: .atomic
            )
            try atomicSwap(live, candidate)
        } catch {
            try? fileManager.removeItem(at: transaction)
            if let failure = error as? RestoreFailure { throw failure }
            throw RestoreFailure(.replacementFailed, error.localizedDescription)
        }

        do {
            try validateState(
                applicationSupportRoot: applicationSupportURL,
                descriptorURL: package.appendingPathComponent("payload/snapshot.json")
            )
        } catch {
            do {
                try atomicSwap(live, candidate)
                try fileManager.removeItem(at: transaction)
            } catch {
                throw RestoreFailure(.postPreRestoreInternalError, error.localizedDescription)
            }
            throw RestoreFailure(.verificationFailed, error.localizedDescription)
        }
    }

    private func validateState(
        applicationSupportRoot: URL,
        descriptorURL: URL
    ) throws {
        let root = applicationSupportRoot.appendingPathComponent(
            "SCREEN-SIMULATION", isDirectory: true
        )
        let descriptorData = try Data(contentsOf: descriptorURL)
        guard let object = try JSONSerialization.jsonObject(with: descriptorData) as? [String: Any],
              Set(object.keys) == ["schema", "includedStatePaths"] else {
            throw RestoreFailure(.snapshotInvalid, "snapshot.json no tiene la forma exacta v1.")
        }
        let descriptor = try JSONDecoder().decode(
            WorkstationSnapshotDescriptor.self, from: descriptorData
        )
        guard descriptor.schema == BackupHubWorkstationProducer.snapshotDocumentSchema,
              descriptor.includedStatePaths == descriptor.includedStatePaths.sorted(),
              Set(descriptor.includedStatePaths).count == descriptor.includedStatePaths.count else {
            throw RestoreFailure(.snapshotInvalid, "El descriptor del snapshot no es válido.")
        }

        let global = root.appendingPathComponent("GlobalLibrary.v17.json")
        if fileManager.fileExists(atPath: global.path) {
            _ = try GlobalLibraryStore(documentURL: global).load()
        }
        let scenesDirectory = root.appendingPathComponent("Library/Scenes", isDirectory: true)
        let scenesDocument = scenesDirectory.appendingPathComponent("Scenes.v28.json")
        var sceneThumbnails = Set<String>()
        if fileManager.fileExists(atPath: scenesDocument.path) {
            let store = try SceneLibraryStore(
                directoryURL: scenesDirectory,
                environmentLibraryRoot: applicationSupportRoot
            )
            let document = try store.load()
            sceneThumbnails = Set(document.scenes.map(\.thumbnailFileName))
        }
        let queueDirectory = root.appendingPathComponent("RenderQueue", isDirectory: true)
        let queue = queueDirectory.appendingPathComponent("RenderQueue.v15.json")
        if fileManager.fileExists(atPath: queue.path) {
            _ = try RenderQueueStore(directoryURL: queueDirectory).load()
        }

        for path in descriptor.includedStatePaths {
            let allowed = path == "GlobalLibrary.v17.json"
                || path == "Library/Scenes/Scenes.v28.json"
                || (path.hasPrefix("Library/Scenes/")
                    && sceneThumbnails.contains(String(path.dropFirst("Library/Scenes/".count))))
                || isAutosavePath(path)
                || isManagedEnvironmentPath(path)
                || path == "RenderQueue/RenderQueue.v15.json"
            guard allowed else {
                throw RestoreFailure(.snapshotInvalid, "Ruta no admitida en snapshot: \(path)")
            }
            try requireRegularFile(root.appendingPathComponent(path), label: path)
        }
        try validateAutosaves(root: root)
        let actual = try managedRelativePaths(root)
        guard actual == descriptor.includedStatePaths else {
            throw RestoreFailure(.snapshotInvalid, "El estado materializado no coincide con snapshot.json.")
        }
    }

    private func validateAutosaves(root: URL) throws {
        let autosaveRoot = root.appendingPathComponent("Library/Autosave.v25", isDirectory: true)
        guard fileManager.fileExists(atPath: autosaveRoot.path) else { return }
        let sceneStore = try SceneLibraryStore(
            directoryURL: root.appendingPathComponent("Library/Scenes", isDirectory: true),
            environmentLibraryRoot: root.deletingLastPathComponent()
        )
        for url in try fileManager.contentsOfDirectory(
            at: autosaveRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  let sceneID = UUID(uuidString: url.lastPathComponent),
                  sceneID.uuidString.lowercased() == url.lastPathComponent else {
                throw RestoreFailure(.snapshotInvalid, "Autosave.v25 contiene una carpeta desconocida.")
            }
            let revisions = try sceneStore.autosaves(for: sceneID)
            let expectedFiles = Set(revisions.flatMap { revision in
                var names = [
                    "\(revision.id.uuidString.lowercased()).json",
                    revision.thumbnailFileName,
                ]
                if let generated = revision.generatedEnvironmentFileName { names.append(generated) }
                return names
            })
            let actualFiles = Set(try regularFiles(under: url).map {
                try relativePath($0, under: url)
            })
            guard actualFiles == expectedFiles else {
                throw RestoreFailure(
                    .snapshotInvalid,
                    "Una carpeta Autosave.v25 contiene archivos sin contrato."
                )
            }
        }
    }

    private func removeCurrentManagedState(from root: URL) throws {
        let fixed = [
            "GlobalLibrary.v17.json",
            "Library/Autosave.v25",
            "Library/Environments/HDRI",
            "RenderQueue/RenderQueue.v15.json",
        ]
        for relative in fixed {
            let url = root.appendingPathComponent(relative)
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
        }
        let scenes = root.appendingPathComponent("Library/Scenes", isDirectory: true)
        if fileManager.fileExists(atPath: scenes.path) {
            for url in try fileManager.contentsOfDirectory(
                at: scenes,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ) where url.lastPathComponent == "Scenes.v28.json" || url.pathExtension == "png" {
                try fileManager.removeItem(at: url)
            }
        }
    }

    private func materializeSnapshot(_ source: URL, at destination: URL) throws {
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        guard fileManager.fileExists(atPath: source.path) else { return }
        for file in try regularFiles(under: source) {
            let relative = try relativePath(file, under: source)
            let target = destination.appendingPathComponent(relative)
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contentsOf: file, options: .mappedIfSafe).write(to: target, options: .atomic)
        }
    }

    private func managedRelativePaths(_ root: URL) throws -> [String] {
        var paths: [String] = []
        for fixed in ["GlobalLibrary.v17.json", "Library/Scenes/Scenes.v28.json", "RenderQueue/RenderQueue.v15.json"] {
            if fileManager.fileExists(atPath: root.appendingPathComponent(fixed).path) { paths.append(fixed) }
        }
        let scenes = root.appendingPathComponent("Library/Scenes", isDirectory: true)
        if fileManager.fileExists(atPath: scenes.path) {
            for file in try regularFiles(under: scenes) where file.pathExtension == "png" {
                paths.append("Library/Scenes/\(file.lastPathComponent)")
            }
        }
        for tree in ["Library/Autosave.v25", "Library/Environments/HDRI"] {
            let url = root.appendingPathComponent(tree, isDirectory: true)
            if fileManager.fileExists(atPath: url.path) {
                for file in try regularFiles(under: url) {
                    paths.append("\(tree)/\(try relativePath(file, under: url))")
                }
            }
        }
        return paths.sorted()
    }

    private func managedStateHash(_ root: URL) throws -> String {
        var hasher = SHA256()
        for path in try managedRelativePaths(root) {
            hasher.update(data: Data(path.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: try Data(contentsOf: root.appendingPathComponent(path)))
            hasher.update(data: Data([0]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func recoverTransaction(requestID: UUID, resultExists: Bool) throws {
        let transaction = transactionURL(requestID)
        guard fileManager.fileExists(atPath: transaction.path) else { return }
        if resultExists {
            try fileManager.removeItem(at: transaction)
            return
        }
        let journal = try JSONDecoder().decode(
            RestoreJournal.self,
            from: Data(contentsOf: transaction.appendingPathComponent("journal.json"))
        )
        guard journal.requestId == requestID else {
            throw WorkstationRestoreConsumerError.invalidRecoveryState
        }
        let candidate = transaction.appendingPathComponent("SCREEN-SIMULATION", isDirectory: true)
        let liveHash = try managedStateHash(liveStateURL)
        let candidateHash = try managedStateHash(candidate)
        if liveHash == journal.candidateHash, candidateHash == journal.previousHash,
           journal.candidateHash != journal.previousHash {
            try atomicSwap(liveStateURL, candidate)
        } else if !(liveHash == journal.previousHash && candidateHash == journal.candidateHash) {
            throw WorkstationRestoreConsumerError.invalidRecoveryState
        }
        try fileManager.removeItem(at: transaction)
    }

    private func commitTransaction(requestID: UUID) throws {
        let transaction = transactionURL(requestID)
        guard fileManager.fileExists(atPath: transaction.path) else {
            throw WorkstationRestoreConsumerError.invalidRecoveryState
        }
        try fileManager.removeItem(at: transaction)
    }

    private func claimPreparedRequests(locations: RestoreLocations) throws {
        for source in try restoreDirectories(at: locations.outbox) {
            let destination = locations.processing.appendingPathComponent(source.lastPathComponent)
            guard !fileManager.fileExists(atPath: destination.path) else { continue }
            try fileManager.moveItem(at: source, to: destination)
        }
    }

    private func publishTerminal(
        _ result: RestoreResultV2,
        claimed: URL,
        locations: RestoreLocations,
        deferClaimFinalization: Bool = false
    ) throws -> WorkstationRestoreRecord {
        try result.validate()
        let destination = locations.resultURL(result.requestId)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw WorkstationRestoreConsumerError.resultAlreadyExists
        }
        let temporary = locations.results.appendingPathComponent(
            ".\(result.requestId.uuidString.lowercased()).tmp"
        )
        try encode(result).write(to: temporary, options: .atomic)
        try fileManager.moveItem(at: temporary, to: destination)
        if !deferClaimFinalization {
            if result.state == .applied || result.state == .cancelled {
                try fileManager.removeItem(at: claimed)
            } else {
                let quarantine = locations.quarantine.appendingPathComponent(claimed.lastPathComponent)
                guard !fileManager.fileExists(atPath: quarantine.path) else {
                    throw WorkstationRestoreConsumerError.quarantineCollision
                }
                try fileManager.moveItem(at: claimed, to: quarantine)
            }
        }
        return result.record
    }

    private func finalizeExistingResult(
        at resultURL: URL,
        claimed: URL,
        locations: RestoreLocations
    ) throws {
        let data = try Data(contentsOf: resultURL)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: RestoreResultV2.keys),
              RestoreResultV2.requiredKeys.isSubset(of: Set(object.keys)),
              (object["error"] == nil || (object["error"] as? [String: Any]).map {
                  Set($0.keys) == RestoreResultV2.Failure.keys
              } == true) else {
            throw RestoreFailure(.postPreRestoreInternalError, "Restore Result v2 no tiene la forma exacta.")
        }
        let result = try JSONDecoder().decode(RestoreResultV2.self, from: data)
        try result.validate()
        if result.state == .applied || result.state == .cancelled {
            try fileManager.removeItem(at: claimed)
        } else {
            let quarantine = locations.quarantine.appendingPathComponent(claimed.lastPathComponent)
            guard !fileManager.fileExists(atPath: quarantine.path) else {
                throw WorkstationRestoreConsumerError.quarantineCollision
            }
            try fileManager.moveItem(at: claimed, to: quarantine)
        }
    }

    private var liveStateURL: URL {
        applicationSupportURL.appendingPathComponent("SCREEN-SIMULATION", isDirectory: true)
    }

    private func transactionURL(_ requestID: UUID) -> URL {
        applicationSupportURL.appendingPathComponent(
            ".screen-simulation-restore-\(requestID.uuidString.lowercased())",
            isDirectory: true
        )
    }

    private func atomicSwap(_ first: URL, _ second: URL) throws {
        let result = first.path.withCString { firstPath in
            second.path.withCString { secondPath in
                renamex_np(firstPath, secondPath, UInt32(RENAME_SWAP))
            }
        }
        guard result == 0 else {
            throw WorkstationRestoreConsumerError.atomicSwapFailed(errno)
        }
    }

    private func regularFiles(under root: URL) throws -> [URL] {
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw RestoreFailure(.snapshotInvalid, "Una raíz del snapshot no es un directorio regular.")
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { throw RestoreFailure(.snapshotInvalid, "No se puede enumerar el snapshot.") }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            ])
            guard values.isSymbolicLink != true else {
                throw RestoreFailure(.snapshotInvalid, "El snapshot contiene un enlace simbólico.")
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else {
                throw RestoreFailure(.snapshotInvalid, "El snapshot contiene un archivo especial.")
            }
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    private func requireRegularFile(_ url: URL, label: String) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw RestoreFailure(.snapshotInvalid, "Falta el archivo regular \(label).")
        }
    }

    private func relativePath(_ url: URL, under root: URL) throws -> String {
        let base = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base) else {
            throw RestoreFailure(.snapshotInvalid, "Una ruta sale de la raíz del snapshot.")
        }
        return String(path.dropFirst(base.count))
    }

    private func isAutosavePath(_ path: String) -> Bool {
        guard path.hasPrefix("Library/Autosave.v25/") else { return false }
        return ["json", "png", "exr"].contains((path as NSString).pathExtension.lowercased())
    }

    private func isManagedEnvironmentPath(_ path: String) -> Bool {
        guard path.hasPrefix("Library/Environments/HDRI/") else { return false }
        return ["json", "exr", "hdr"].contains((path as NSString).pathExtension.lowercased())
    }

    private func restoreDirectories(at directory: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ).filter { url in
            guard !url.lastPathComponent.hasPrefix("."), url.pathExtension == "bhrestore",
                  UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil,
                  let values = try? url.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                  ) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func requestID(from directory: URL) throws -> UUID {
        guard let id = UUID(uuidString: directory.deletingPathExtension().lastPathComponent) else {
            throw RestoreFailure(.requestInvalid, "La carpeta de restore no tiene un UUID válido.")
        }
        return id
    }

    private func decodeRequest(at url: URL, directoryRequestID: UUID) throws -> RestoreRequestV2 {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == RestoreRequestV2.keys,
              let summary = root["backupSummary"] as? [String: Any],
              Set(summary.keys) == WorkstationRestoreSummary.keys else {
            throw RestoreFailure(.requestInvalid, "request.json no cumple Restore Handoff v2.")
        }
        let request = try JSONDecoder().decode(RestoreRequestV2.self, from: data)
        guard request.requestId == directoryRequestID,
              request.manifestSha256 == request.manifestSha256.lowercased(),
              isLowercaseSHA256(request.manifestSha256) else {
            throw RestoreFailure(.requestInvalid, "La identidad o hash de request.json no es válido.")
        }
        return request
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isNumber || ("a" ... "f").contains(String($0)) }
    }

    private func isRFC3339(_ value: String) -> Bool {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if fractional.date(from: value) != nil { return true }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: value) != nil
    }
}

private struct RestoreLocations {
    let vault: URL
    var outbox: URL { vault.appendingPathComponent("restore-outbox/screen-simulation", isDirectory: true) }
    var processing: URL { vault.appendingPathComponent("restore-processing/screen-simulation", isDirectory: true) }
    var results: URL { vault.appendingPathComponent("restore-results/screen-simulation", isDirectory: true) }
    var quarantine: URL { vault.appendingPathComponent("restore-quarantine/screen-simulation", isDirectory: true) }
    var retired: URL { vault.appendingPathComponent("restore-retired-v1-processing/screen-simulation", isDirectory: true) }
    var ownerMarker: URL { vault.appendingPathComponent("restore-owner-protocol/screen-simulation.version") }

    func resultURL(_ id: UUID) -> URL {
        results.appendingPathComponent("\(id.uuidString.lowercased()).json")
    }

    func prepareOwnership(fileManager: FileManager) throws {
        let markerDirectory = ownerMarker.deletingLastPathComponent()
        try fileManager.createDirectory(at: markerDirectory, withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: ownerMarker.path) {
            let values = try ownerMarker.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  try Data(contentsOf: ownerMarker) == Data("2\n".utf8) else {
                throw WorkstationRestoreConsumerError.invalidOwnerProtocolMarker
            }
        } else {
            let processingExists = fileManager.fileExists(atPath: processing.path)
            let retiredExists = fileManager.fileExists(atPath: retired.path)
            guard !(processingExists && retiredExists) else {
                throw WorkstationRestoreConsumerError.ownerProtocolCutoverCollision
            }
            if processingExists {
                try fileManager.createDirectory(
                    at: retired.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: processing, to: retired)
            }
            try Data("2\n".utf8).write(to: ownerMarker, options: .atomic)
        }
        for directory in [outbox, processing, results, quarantine] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

private struct RestoreRequestV2: Codable {
    static let keys: Set<String> = [
        "handoffVersion", "requestId", "applicationId", "packageId", "preparedAt",
        "vaultObjectSha256", "manifestSha256", "backupSummary", "state",
    ]
    let handoffVersion: Int
    let requestId: UUID
    let applicationId: String
    let packageId: UUID
    let preparedAt: String
    let vaultObjectSha256: String
    let manifestSha256: String
    let backupSummary: WorkstationRestoreSummary
    let state: String
}

private extension WorkstationRestoreSummary {
    static let keys: Set<String> = [
        "createdAt", "reason", "snapshotFormat", "snapshotSchemaVersion", "fileCount", "totalBytes",
    ]
}

private struct RestoreJournal: Codable {
    let requestId: UUID
    let preRestorePackageId: UUID
    let previousHash: String
    let candidateHash: String
}

private struct RestoreFailure: Error {
    let code: WorkstationRestoreErrorCode
    let message: String

    init(_ code: WorkstationRestoreErrorCode, _ message: String) {
        self.code = code
        self.message = message.isEmpty ? "Error de restore sin detalle." : message
    }
}

private struct RestoreResultV2: Codable {
    static let keys: Set<String> = [
        "handoffVersion", "requestId", "applicationId", "packageId",
        "preRestorePackageId", "completedAt", "state", "userDecision", "error",
    ]
    static let requiredKeys: Set<String> = [
        "handoffVersion", "requestId", "applicationId", "completedAt", "state", "userDecision",
    ]
    struct Failure: Codable {
        static let keys: Set<String> = ["code", "message"]
        let code: WorkstationRestoreErrorCode
        let message: String
    }
    let handoffVersion: Int
    let requestId: UUID
    let applicationId: String
    let packageId: UUID?
    let preRestorePackageId: UUID?
    let completedAt: String
    let state: WorkstationRestoreState
    let userDecision: WorkstationRestoreDecision
    let error: Failure?

    private enum CodingKeys: String, CodingKey {
        case handoffVersion, requestId, applicationId, packageId, preRestorePackageId
        case completedAt, state, userDecision, error
    }

    init(
        handoffVersion: Int,
        requestId: UUID,
        applicationId: String,
        packageId: UUID?,
        preRestorePackageId: UUID?,
        completedAt: String,
        state: WorkstationRestoreState,
        userDecision: WorkstationRestoreDecision,
        error: Failure?
    ) {
        self.handoffVersion = handoffVersion
        self.requestId = requestId
        self.applicationId = applicationId
        self.packageId = packageId
        self.preRestorePackageId = preRestorePackageId
        self.completedAt = completedAt
        self.state = state
        self.userDecision = userDecision
        self.error = error
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        handoffVersion = try values.decode(Int.self, forKey: .handoffVersion)
        requestId = try Self.decodeUUID(values, key: .requestId)
        applicationId = try values.decode(String.self, forKey: .applicationId)
        packageId = try Self.decodeOptionalUUID(values, key: .packageId)
        preRestorePackageId = try Self.decodeOptionalUUID(values, key: .preRestorePackageId)
        completedAt = try values.decode(String.self, forKey: .completedAt)
        state = try values.decode(WorkstationRestoreState.self, forKey: .state)
        userDecision = try values.decode(WorkstationRestoreDecision.self, forKey: .userDecision)
        error = try values.decodeIfPresent(Failure.self, forKey: .error)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(handoffVersion, forKey: .handoffVersion)
        try values.encode(requestId.uuidString.lowercased(), forKey: .requestId)
        try values.encode(applicationId, forKey: .applicationId)
        try values.encodeIfPresent(packageId?.uuidString.lowercased(), forKey: .packageId)
        try values.encodeIfPresent(
            preRestorePackageId?.uuidString.lowercased(), forKey: .preRestorePackageId
        )
        try values.encode(completedAt, forKey: .completedAt)
        try values.encode(state, forKey: .state)
        try values.encode(userDecision, forKey: .userDecision)
        try values.encodeIfPresent(error, forKey: .error)
    }

    private static func decodeUUID(
        _ values: KeyedDecodingContainer<CodingKeys>, key: CodingKeys
    ) throws -> UUID {
        let value = try values.decode(String.self, forKey: key)
        guard value == value.lowercased(), let result = UUID(uuidString: value) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: values, debugDescription: "UUID no canónico"
            )
        }
        return result
    }

    private static func decodeOptionalUUID(
        _ values: KeyedDecodingContainer<CodingKeys>, key: CodingKeys
    ) throws -> UUID? {
        guard let value = try values.decodeIfPresent(String.self, forKey: key) else { return nil }
        guard value == value.lowercased(), let result = UUID(uuidString: value) else {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: values, debugDescription: "UUID no canónico"
            )
        }
        return result
    }

    var record: WorkstationRestoreRecord {
        .init(
            requestID: requestId,
            packageID: packageId,
            preRestorePackageID: preRestorePackageId,
            state: state,
            errorCode: error?.code,
            errorMessage: error?.message
        )
    }

    static func requestInvalid(requestID: UUID, date: Date, message: String) -> Self {
        .init(
            handoffVersion: 2, requestId: requestID, applicationId: "screen-simulation",
            packageId: nil, preRestorePackageId: nil, completedAt: timestamp(date),
            state: .rejected, userDecision: .notPresented,
            error: .init(code: .requestInvalid, message: nonempty(message))
        )
    }

    static func rejected(
        request: RestoreRequestV2, requestID: UUID, date: Date,
        code: WorkstationRestoreErrorCode, message: String
    ) -> Self {
        .init(
            handoffVersion: 2, requestId: requestID, applicationId: "screen-simulation",
            packageId: request.packageId, preRestorePackageId: nil, completedAt: timestamp(date),
            state: .rejected, userDecision: .notPresented,
            error: .init(code: code, message: nonempty(message))
        )
    }

    static func cancelled(request: RestoreRequestV2, requestID: UUID, date: Date) -> Self {
        .init(
            handoffVersion: 2, requestId: requestID, applicationId: "screen-simulation",
            packageId: request.packageId, preRestorePackageId: nil, completedAt: timestamp(date),
            state: .cancelled, userDecision: .cancelled, error: nil
        )
    }

    static func failed(
        request: RestoreRequestV2, requestID: UUID, date: Date,
        decision: WorkstationRestoreDecision, preRestorePackageID: UUID? = nil,
        code: WorkstationRestoreErrorCode, message: String
    ) -> Self {
        .init(
            handoffVersion: 2, requestId: requestID, applicationId: "screen-simulation",
            packageId: request.packageId, preRestorePackageId: preRestorePackageID,
            completedAt: timestamp(date), state: .failed, userDecision: decision,
            error: .init(code: code, message: nonempty(message))
        )
    }

    static func applied(
        request: RestoreRequestV2, requestID: UUID,
        preRestorePackageID: UUID, date: Date
    ) -> Self {
        .init(
            handoffVersion: 2, requestId: requestID, applicationId: "screen-simulation",
            packageId: request.packageId, preRestorePackageId: preRestorePackageID,
            completedAt: timestamp(date), state: .applied, userDecision: .confirmed, error: nil
        )
    }

    func validate() throws {
        guard handoffVersion == 2, applicationId == "screen-simulation",
              isRestoreTimestamp(completedAt),
              packageId == nil || packageId != preRestorePackageId else {
            throw RestoreFailure(.postPreRestoreInternalError, "Restore Result v2 inválido.")
        }
        switch (state, userDecision, packageId, preRestorePackageId, error?.code) {
        case (.applied, .confirmed, .some, .some, nil),
             (.cancelled, .cancelled, .some, nil, nil),
             (.rejected, .notPresented, nil, nil, .requestInvalid),
             (.rejected, .notPresented, .some, nil, .identityMismatch),
             (.rejected, .notPresented, .some, nil, .contractMismatch),
             (.rejected, .notPresented, .some, nil, .manifestHashMismatch),
             (.rejected, .notPresented, .some, nil, .payloadIncomplete),
             (.rejected, .notPresented, .some, nil, .payloadHashMismatch),
             (.rejected, .notPresented, .some, nil, .snapshotInvalid),
             (.failed, .notPresented, .some, nil, .confirmationFailed),
             (.failed, .confirmed, .some, nil, .preRestoreBackupFailed),
             (.failed, .confirmed, .some, .some, .replacementFailed),
             (.failed, .confirmed, .some, .some, .verificationFailed),
             (.failed, .confirmed, .some, .some, .postPreRestoreInternalError): return
        default: throw RestoreFailure(.postPreRestoreInternalError, "Restore Result v2 inválido.")
        }
    }
}

private func isRestoreTimestamp(_ value: String) -> Bool {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if fractional.date(from: value) != nil { return true }
    let whole = ISO8601DateFormatter()
    whole.formatOptions = [.withInternetDateTime]
    return whole.date(from: value) != nil
}

private func timestamp(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: date)
}

private func nonempty(_ message: String) -> String {
    message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        ? "Error de restore sin detalle." : message
}
