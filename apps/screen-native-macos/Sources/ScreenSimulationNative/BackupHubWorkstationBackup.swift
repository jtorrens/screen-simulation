import AppKit
import CoreFoundation
import CryptoKit
import Foundation

enum WorkstationBackupReason: String, Codable {
    case cleanExit = "clean-exit"
    case manual
    case preRestore = "pre-restore"
}

enum WorkstationBackupError: LocalizedError {
    case backupHubUnavailable(String)
    case invalidState(String)
    case publicationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .backupHubUnavailable(detail):
            "Backup Hub no está preparado: \(detail). Instálalo y ábrelo una vez antes de crear backups."
        case let .invalidState(detail):
            "El estado de SCREEN-SIMULATION no permite crear un backup coherente: \(detail)"
        case let .publicationFailed(detail):
            "No se pudo publicar el backup en Backup Hub: \(detail)"
        }
    }
}

struct BackupHubWorkstationProducer {
    static let applicationID = "screen-simulation"
    static let snapshotFormat = "screen-simulation-workstation"
    static let snapshotSchemaVersion = "1"
    static let snapshotDocumentSchema = "ScreenSimulation.WorkstationSnapshot.v1"

    private let applicationSupportURL: URL
    private let producerVersion: () throws -> String
    private let makePackageID: () -> UUID
    private let now: () -> Date
    private let fileManager: FileManager

    init(
        applicationSupportURL: URL? = nil,
        producerVersion: @escaping () throws -> String = {
            guard let version = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String,
            !version.isEmpty else {
                throw WorkstationBackupError.publicationFailed(
                    "la aplicación instalada no declara CFBundleShortVersionString"
                )
            }
            return version
        },
        makePackageID: @escaping () -> UUID = UUID.init,
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
        self.makePackageID = makePackageID
        self.now = now
        self.fileManager = fileManager
    }

    @discardableResult
    func publish(reason: WorkstationBackupReason) throws -> URL {
        try publishPackage(reason: reason).url
    }

    func publishPackage(reason: WorkstationBackupReason) throws -> PublishedWorkstationBackup {
        let inbox = try validatedInboxURL()
        let packageID = makePackageID().uuidString.lowercased()
        let stagingURL = inbox.appendingPathComponent(".\(packageID).tmp", isDirectory: true)
        let publishedURL = inbox.appendingPathComponent("\(packageID).bhpkg", isDirectory: true)

        guard !fileManager.fileExists(atPath: stagingURL.path),
              !fileManager.fileExists(atPath: publishedURL.path) else {
            throw WorkstationBackupError.publicationFailed(
                "ya existe un paquete con la identidad \(packageID)"
            )
        }

        do {
            let payloadURL = stagingURL.appendingPathComponent("payload", isDirectory: true)
            try fileManager.createDirectory(at: payloadURL, withIntermediateDirectories: true)
            let includedStatePaths = try writeSnapshotPayload(to: payloadURL)
            let snapshot = WorkstationSnapshotDescriptor(
                schema: Self.snapshotDocumentSchema,
                includedStatePaths: includedStatePaths
            )
            try encoded(snapshot).write(
                to: payloadURL.appendingPathComponent("snapshot.json"), options: .atomic
            )

            let files = try payloadFiles(at: payloadURL)
            let version = try producerVersion()
            guard !version.isEmpty else {
                throw WorkstationBackupError.publicationFailed("la versión del productor está vacía")
            }
            let manifest = BackupPackageManifest(
                contractVersion: 1,
                packageId: packageID,
                applicationId: Self.applicationID,
                createdAt: Self.timestamp(now()),
                reason: reason.rawValue,
                producer: .init(version: version, platform: "macos"),
                snapshot: .init(
                    format: Self.snapshotFormat,
                    schemaVersion: Self.snapshotSchemaVersion
                ),
                files: files
            )
            try encoded(manifest).write(
                to: stagingURL.appendingPathComponent("manifest.json"), options: .atomic
            )
            try validatePackage(at: stagingURL, expectedManifest: manifest)
            try fileManager.moveItem(at: stagingURL, to: publishedURL)
            return PublishedWorkstationBackup(
                packageID: UUID(uuidString: packageID)!,
                url: publishedURL
            )
        } catch {
            if fileManager.fileExists(atPath: stagingURL.path) {
                try? fileManager.removeItem(at: stagingURL)
            }
            if let error = error as? WorkstationBackupError { throw error }
            throw WorkstationBackupError.publicationFailed(error.localizedDescription)
        }
    }

    func validatedVaultURL() throws -> URL {
        let vault = applicationSupportURL
            .appendingPathComponent("com.jtorrens.backup-hub", isDirectory: true)
            .appendingPathComponent("vault", isDirectory: true)
        let marker = vault.appendingPathComponent("vault-layout.json")
        do { try requireRegularNonSymbolicFile(marker, context: "vault-layout.json") }
        catch {
            throw WorkstationBackupError.backupHubUnavailable(
                "falta un vault-layout.json regular en la ubicación canónica"
            )
        }
        let data: Data
        do { data = try Data(contentsOf: marker) }
        catch {
            throw WorkstationBackupError.backupHubUnavailable(
                "no se puede leer vault-layout.json"
            )
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["layoutVersion", "vaultId"],
              let layoutVersion = object["layoutVersion"] as? NSNumber,
              CFGetTypeID(layoutVersion) != CFBooleanGetTypeID(),
              layoutVersion.doubleValue == 1,
              object["vaultId"] as? String == "com.jtorrens.backup-hub" else {
            throw WorkstationBackupError.backupHubUnavailable(
                "vault-layout.json no cumple Vault Location v1"
            )
        }
        return vault
    }

    private func validatedInboxURL() throws -> URL {
        let vault = try validatedVaultURL()
        let inbox = vault.appendingPathComponent("inbox", isDirectory: true)
        let values = try? inbox.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey,
        ])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else {
            throw WorkstationBackupError.backupHubUnavailable(
                "falta el directorio canónico inbox"
            )
        }
        return inbox
    }

    private func writeSnapshotPayload(to payloadURL: URL) throws -> [String] {
        let stateRoot = applicationSupportURL
            .appendingPathComponent("SCREEN-SIMULATION", isDirectory: true)
        let destinationRoot = payloadURL.appendingPathComponent("state", isDirectory: true)
        var sources: [(relativePath: String, url: URL)] = []

        let globalLibrary = stateRoot.appendingPathComponent("GlobalLibrary.v17.json")
        if fileManager.fileExists(atPath: globalLibrary.path) {
            _ = try GlobalLibraryStore(documentURL: globalLibrary).load()
            sources.append(("GlobalLibrary.v17.json", globalLibrary))
        }

        let scenesDirectory = stateRoot
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Scenes", isDirectory: true)
        let scenesDocument = scenesDirectory.appendingPathComponent("Scenes.v28.json")
        if fileManager.fileExists(atPath: scenesDocument.path) {
            let store = try SceneLibraryStore(
                directoryURL: scenesDirectory,
                environmentLibraryRoot: applicationSupportURL
            )
            let document = try store.load()
            sources.append(("Library/Scenes/Scenes.v28.json", scenesDocument))
            for scene in document.scenes {
                sources.append(("Library/Scenes/\(scene.thumbnailFileName)", store.thumbnailURL(for: scene)))
            }
        }

        try appendTree(
            at: stateRoot.appendingPathComponent("Library/Autosave.v25", isDirectory: true),
            relativeRoot: "Library/Autosave.v25",
            to: &sources
        )
        try appendTree(
            at: stateRoot.appendingPathComponent("Library/Environments/HDRI", isDirectory: true),
            relativeRoot: "Library/Environments/HDRI",
            to: &sources
        )

        let queueDirectory = stateRoot.appendingPathComponent("RenderQueue", isDirectory: true)
        let queueDocument = queueDirectory.appendingPathComponent("RenderQueue.v15.json")
        if fileManager.fileExists(atPath: queueDocument.path) {
            _ = try RenderQueueStore(directoryURL: queueDirectory).load()
            sources.append(("RenderQueue/RenderQueue.v15.json", queueDocument))
        }

        let ordered = sources.sorted { $0.relativePath < $1.relativePath }
        guard Set(ordered.map(\.relativePath)).count == ordered.count else {
            throw WorkstationBackupError.invalidState("hay rutas de snapshot duplicadas")
        }
        for source in ordered {
            try validateRelativePath(source.relativePath)
            try requireRegularNonSymbolicFile(source.url, context: source.relativePath)
            let destination = destinationRoot.appendingPathComponent(source.relativePath)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(contentsOf: source.url, options: .mappedIfSafe).write(
                to: destination, options: .atomic
            )
        }
        return ordered.map(\.relativePath)
    }

    private func appendTree(
        at root: URL,
        relativeRoot: String,
        to sources: inout [(relativePath: String, url: URL)]
    ) throws {
        guard fileManager.fileExists(atPath: root.path) else { return }
        let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw WorkstationBackupError.invalidState("\(relativeRoot) no es un directorio regular")
        }
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw WorkstationBackupError.invalidState("no se puede enumerar \(relativeRoot)")
        }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            ])
            guard values.isSymbolicLink != true else {
                throw WorkstationBackupError.invalidState("\(url.lastPathComponent) es un enlace simbólico")
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else {
                throw WorkstationBackupError.invalidState("\(url.lastPathComponent) no es un archivo regular")
            }
            let rootPath = root.standardizedFileURL.path
            let filePath = url.standardizedFileURL.path
            guard filePath.hasPrefix(rootPath + "/") else {
                throw WorkstationBackupError.invalidState("una ruta sale de \(relativeRoot)")
            }
            let suffix = String(filePath.dropFirst(rootPath.count + 1))
            sources.append(("\(relativeRoot)/\(suffix)", url))
        }
    }

    func payloadFiles(at payloadURL: URL) throws -> [BackupPackageFile] {
        var result: [BackupPackageFile] = []
        guard let enumerator = fileManager.enumerator(
            at: payloadURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else { throw WorkstationBackupError.publicationFailed("no se puede enumerar payload") }
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
            ])
            guard values.isSymbolicLink != true else {
                throw WorkstationBackupError.publicationFailed("payload contiene un enlace simbólico")
            }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else {
                throw WorkstationBackupError.publicationFailed("payload contiene un archivo especial")
            }
            let path = try relativePath(of: url, under: payloadURL)
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            result.append(.init(
                path: path,
                byteLength: data.count,
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            ))
        }
        return result.sorted { $0.path < $1.path }
    }

    func validatePackage(
        at packageURL: URL,
        expectedManifest: BackupPackageManifest
    ) throws {
        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == [
                "contractVersion", "packageId", "applicationId", "createdAt", "reason",
                "producer", "snapshot", "files",
              ],
              let producer = root["producer"] as? [String: Any],
              Set(producer.keys) == ["version", "platform"],
              let snapshot = root["snapshot"] as? [String: Any],
              Set(snapshot.keys) == ["format", "schemaVersion"] else {
            throw WorkstationBackupError.publicationFailed("manifest.json no tiene la forma exacta v1")
        }
        let decoded = try JSONDecoder().decode(BackupPackageManifest.self, from: data)
        guard decoded == expectedManifest,
              decoded.contractVersion == 1,
              UUID(uuidString: decoded.packageId)?.uuidString.lowercased() == decoded.packageId,
              decoded.applicationId == Self.applicationID,
              isRFC3339(decoded.createdAt),
              ["clean-exit", "manual", "pre-migration", "pre-restore"].contains(decoded.reason),
              !decoded.producer.version.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              decoded.producer.platform == "macos",
              decoded.snapshot.format == Self.snapshotFormat,
              decoded.snapshot.schemaVersion == Self.snapshotSchemaVersion,
              !decoded.files.isEmpty,
              Set(decoded.files.map(\.path)).count == decoded.files.count,
              decoded.files.allSatisfy({
                  $0.byteLength >= 0 && isLowercaseSHA256($0.sha256)
              }) else {
            throw WorkstationBackupError.publicationFailed("manifest.json no cumple Backup Package v1")
        }
        let actualFiles = try payloadFiles(at: packageURL.appendingPathComponent("payload"))
        guard actualFiles == decoded.files else {
            throw WorkstationBackupError.publicationFailed("payload no coincide con manifest.json")
        }
        let descriptorData = try Data(contentsOf: packageURL.appendingPathComponent("payload/snapshot.json"))
        guard let descriptorObject = try JSONSerialization.jsonObject(
            with: descriptorData
        ) as? [String: Any],
        Set(descriptorObject.keys) == ["schema", "includedStatePaths"] else {
            throw WorkstationBackupError.publicationFailed("snapshot.json no tiene la forma exacta v1")
        }
        let descriptor = try JSONDecoder().decode(
            WorkstationSnapshotDescriptor.self, from: descriptorData
        )
        let actualStatePaths = actualFiles.map(\.path).filter { $0.hasPrefix("state/") }
            .map { String($0.dropFirst("state/".count)) }
        guard descriptor.schema == Self.snapshotDocumentSchema,
              descriptor.includedStatePaths == actualStatePaths else {
            throw WorkstationBackupError.publicationFailed("snapshot.json no coincide con el estado incluido")
        }
    }

    func validatedRestoreManifest(
        at packageURL: URL,
        expectedPackageID: UUID
    ) throws -> BackupPackageManifest {
        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        let data = try Data(contentsOf: manifestURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == [
                "contractVersion", "packageId", "applicationId", "createdAt", "reason",
                "producer", "snapshot", "files",
              ],
              let producer = root["producer"] as? [String: Any],
              Set(producer.keys) == ["version", "platform"],
              let snapshot = root["snapshot"] as? [String: Any],
              Set(snapshot.keys) == ["format", "schemaVersion"],
              let rawFiles = root["files"] as? [[String: Any]],
              rawFiles.allSatisfy({ Set($0.keys) == ["path", "byteLength", "sha256"] }) else {
            throw WorkstationBackupError.publicationFailed("manifest.json no tiene la forma exacta v1")
        }
        let manifest = try JSONDecoder().decode(BackupPackageManifest.self, from: data)
        guard manifest.packageId.lowercased() == expectedPackageID.uuidString.lowercased(),
              manifest.applicationId == Self.applicationID,
              manifest.snapshot.format == Self.snapshotFormat,
              manifest.snapshot.schemaVersion == Self.snapshotSchemaVersion else {
            throw WorkstationBackupError.publicationFailed("la identidad del paquete no coincide")
        }
        try validatePackage(at: packageURL, expectedManifest: manifest)
        return manifest
    }

    private func isRFC3339(_ value: String) -> Bool {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if fractional.date(from: value) != nil { return true }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: value) != nil
    }

    private func isLowercaseSHA256(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy {
            $0.isNumber || ("a" ... "f").contains(String($0))
        }
    }

    private func requireRegularNonSymbolicFile(_ url: URL, context: String) throws {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        } catch {
            throw WorkstationBackupError.invalidState("falta \(context)")
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw WorkstationBackupError.invalidState("\(context) no es un archivo regular")
        }
    }

    private func relativePath(of url: URL, under root: URL) throws -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        guard filePath.hasPrefix(rootPath + "/") else {
            throw WorkstationBackupError.publicationFailed("una ruta sale de payload")
        }
        let result = String(filePath.dropFirst(rootPath.count + 1))
        try validateRelativePath(result)
        return result
    }

    private func validateRelativePath(_ path: String) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.hasPrefix("/"), !path.contains("\\"),
              !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw WorkstationBackupError.publicationFailed("ruta relativa no válida: \(path)")
        }
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

struct PublishedWorkstationBackup {
    let packageID: UUID
    let url: URL
}

struct WorkstationSnapshotDescriptor: Codable, Equatable {
    let schema: String
    let includedStatePaths: [String]
}

struct BackupPackageManifest: Codable, Equatable {
    struct Producer: Codable, Equatable {
        let version: String
        let platform: String
    }

    struct Snapshot: Codable, Equatable {
        let format: String
        let schemaVersion: String
    }

    let contractVersion: Int
    let packageId: String
    let applicationId: String
    let createdAt: String
    let reason: String
    let producer: Producer
    let snapshot: Snapshot
    let files: [BackupPackageFile]
}

struct BackupPackageFile: Codable, Equatable {
    let path: String
    let byteLength: Int
    let sha256: String
}

@MainActor
final class WorkstationBackupController: ObservableObject {
    static let shared = WorkstationBackupController()

    @Published private(set) var lastPublishedMessage: String?
    private var cleanExitWasPublished = false

    func publishManual() throws {
        let url = try BackupHubWorkstationProducer().publish(reason: .manual)
        lastPublishedMessage = "Backup publicado en Backup Hub: \(url.lastPathComponent)"
    }

    func publishCleanExitIfNeeded() throws {
        guard !cleanExitWasPublished else { return }
        _ = try BackupHubWorkstationProducer().publish(reason: .cleanExit)
        cleanExitWasPublished = true
    }
}

@MainActor
final class ScreenSimulationAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        do {
            try WorkstationBackupController.shared.publishCleanExitIfNeeded()
            return .terminateNow
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "No se pudo crear el backup de salida"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "Cancelar salida")
            alert.addButton(withTitle: "Salir sin backup")
            return alert.runModal() == .alertFirstButtonReturn ? .terminateCancel : .terminateNow
        }
    }
}
