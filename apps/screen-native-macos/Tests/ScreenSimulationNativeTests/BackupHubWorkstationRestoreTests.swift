import CryptoKit
import Foundation
import Testing
@testable import ScreenSimulationNative

@Test func workstationRestoreAppliesAtomicallyAndPublishesPreviousVersion() throws {
    let fixture = try RestoreFixture()
    defer { fixture.remove() }
    let selectedID = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440010")!
    let preRestoreID = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440011")!
    try fixture.writeManagedEnvironment(name: "desired.exr", contents: "desired")
    let requestID = try fixture.prepareRequest(packageID: selectedID)

    try FileManager.default.removeItem(at: fixture.state)
    try fixture.writeManagedEnvironment(name: "current.exr", contents: "current")
    try Data("preserve".utf8).write(to: fixture.state.appendingPathComponent("Legacy.txt"))

    let consumer = try BackupHubWorkstationRestoreConsumer(
        applicationSupportURL: fixture.support,
        producerVersion: { "1.0" },
        makePreRestorePackageID: { preRestoreID },
        now: { Date(timeIntervalSince1970: 2) }
    )
    var confirmations: [WorkstationRestoreConfirmation] = []
    let records = try consumer.processPendingRestores { value in
        confirmations.append(value)
        return .confirmed
    }

    #expect(records.count == 1)
    #expect(records.first?.state == .applied)
    #expect(records.first?.packageID == selectedID)
    #expect(records.first?.preRestorePackageID == preRestoreID)
    #expect(confirmations.first?.requestID == requestID)
    #expect(confirmations.first?.packageID == selectedID)
    #expect(confirmations.first?.summary.snapshotFormat == "screen-simulation-workstation")
    #expect(try String(contentsOf: fixture.managedEnvironment("desired.exr"), encoding: .utf8) == "desired")
    #expect(!FileManager.default.fileExists(atPath: fixture.managedEnvironment("current.exr").path))
    #expect(try String(contentsOf: fixture.state.appendingPathComponent("Legacy.txt"), encoding: .utf8) == "preserve")
    #expect(try Data(contentsOf: fixture.vault.appendingPathComponent(
        "restore-owner-protocol/screen-simulation.version"
    )) == Data("2\n".utf8))
    #expect(!FileManager.default.fileExists(atPath: fixture.processingRequest(requestID).path))

    let result = try fixture.result(requestID)
    #expect(result["state"] as? String == "applied")
    #expect(result["userDecision"] as? String == "confirmed")
    #expect(result["packageId"] as? String == selectedID.uuidString.lowercased())
    #expect(result["preRestorePackageId"] as? String == preRestoreID.uuidString.lowercased())
    let preRestore = fixture.inbox.appendingPathComponent(
        "\(preRestoreID.uuidString.lowercased()).bhpkg"
    )
    let preManifest = try fixture.json(preRestore.appendingPathComponent("manifest.json"))
    #expect(preManifest["reason"] as? String == "pre-restore")
}

@Test func workstationRestoreCancellationChangesNoStateAndCreatesNoBackup() throws {
    let fixture = try RestoreFixture()
    defer { fixture.remove() }
    let selectedID = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440020")!
    try fixture.writeManagedEnvironment(name: "selected.exr", contents: "selected")
    let requestID = try fixture.prepareRequest(packageID: selectedID)
    try FileManager.default.removeItem(at: fixture.state)
    try fixture.writeManagedEnvironment(name: "current.exr", contents: "current")

    let consumer = try BackupHubWorkstationRestoreConsumer(
        applicationSupportURL: fixture.support,
        producerVersion: { "1.0" }
    )
    let records = try consumer.processPendingRestores { _ in .cancelled }

    #expect(records.first?.state == .cancelled)
    #expect(try String(contentsOf: fixture.managedEnvironment("current.exr"), encoding: .utf8) == "current")
    #expect(!FileManager.default.fileExists(atPath: fixture.managedEnvironment("selected.exr").path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.inbox.path).isEmpty)
    let result = try fixture.result(requestID)
    #expect(result["state"] as? String == "cancelled")
    #expect(result["userDecision"] as? String == "cancelled")
    #expect(result["preRestorePackageId"] == nil)
}

@Test func workstationRestoreRejectsAlteredPayloadWithoutConfirmationOrMutation() throws {
    let fixture = try RestoreFixture()
    defer { fixture.remove() }
    let selectedID = UUID(uuidString: "550e8400-e29b-41d4-a716-446655440030")!
    try fixture.writeManagedEnvironment(name: "selected.exr", contents: "selected")
    let requestID = try fixture.prepareRequest(packageID: selectedID)
    try Data("altered".utf8).write(
        to: fixture.outboxRequest(requestID)
            .appendingPathComponent("package/payload/state/Library/Environments/HDRI/selected.exr")
    )
    try FileManager.default.removeItem(at: fixture.state)
    try fixture.writeManagedEnvironment(name: "current.exr", contents: "current")

    var confirmationWasPresented = false
    let consumer = try BackupHubWorkstationRestoreConsumer(
        applicationSupportURL: fixture.support,
        producerVersion: { "1.0" }
    )
    let records = try consumer.processPendingRestores { _ in
        confirmationWasPresented = true
        return .confirmed
    }

    #expect(records.first?.state == .rejected)
    #expect(records.first?.errorCode == .payloadHashMismatch)
    #expect(!confirmationWasPresented)
    #expect(try String(contentsOf: fixture.managedEnvironment("current.exr"), encoding: .utf8) == "current")
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.inbox.path).isEmpty)
    #expect(FileManager.default.fileExists(atPath: fixture.quarantineRequest(requestID).path))
    let result = try fixture.result(requestID)
    #expect(result["state"] as? String == "rejected")
    #expect((result["error"] as? [String: Any])?["code"] as? String == "payload-hash-mismatch")
}

private final class RestoreFixture {
    let support: URL
    let state: URL
    let vault: URL
    let inbox: URL

    init() throws {
        support = FileManager.default.temporaryDirectory
            .appendingPathComponent("screen-restore-tests-\(UUID().uuidString)", isDirectory: true)
        state = support.appendingPathComponent("SCREEN-SIMULATION", isDirectory: true)
        vault = support.appendingPathComponent("com.jtorrens.backup-hub/vault", isDirectory: true)
        inbox = vault.appendingPathComponent("inbox", isDirectory: true)
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try Data(#"{"layoutVersion":1,"vaultId":"com.jtorrens.backup-hub"}"#.utf8)
            .write(to: vault.appendingPathComponent("vault-layout.json"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: support)
    }

    func managedEnvironment(_ name: String) -> URL {
        state.appendingPathComponent("Library/Environments/HDRI/\(name)")
    }

    func writeManagedEnvironment(name: String, contents: String) throws {
        let url = managedEnvironment(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
    }

    func prepareRequest(packageID: UUID) throws -> UUID {
        let producer = try BackupHubWorkstationProducer(
            applicationSupportURL: support,
            producerVersion: { "1.0" },
            makePackageID: { packageID },
            now: { Date(timeIntervalSince1970: 1) }
        )
        let package = try producer.publishPackage(reason: .manual)
        let requestID = UUID()
        let request = outboxRequest(requestID)
        try FileManager.default.createDirectory(at: request, withIntermediateDirectories: true)
        try FileManager.default.moveItem(
            at: package.url,
            to: request.appendingPathComponent("package", isDirectory: true)
        )
        let manifestURL = request.appendingPathComponent("package/manifest.json")
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest = try json(manifestURL)
        let files = manifest["files"] as! [[String: Any]]
        let total = files.reduce(0) { $0 + (($1["byteLength"] as! NSNumber).intValue) }
        let snapshot = manifest["snapshot"] as! [String: String]
        let requestDocument: [String: Any] = [
            "handoffVersion": 2,
            "requestId": requestID.uuidString.lowercased(),
            "applicationId": "screen-simulation",
            "packageId": packageID.uuidString.lowercased(),
            "preparedAt": "1970-01-01T00:00:01.000Z",
            "vaultObjectSha256": String(repeating: "0", count: 64),
            "manifestSha256": sha256(manifestData),
            "backupSummary": [
                "createdAt": manifest["createdAt"] as! String,
                "reason": manifest["reason"] as! String,
                "snapshotFormat": snapshot["format"]!,
                "snapshotSchemaVersion": snapshot["schemaVersion"]!,
                "fileCount": files.count,
                "totalBytes": total,
            ],
            "state": "prepared",
        ]
        let data = try JSONSerialization.data(
            withJSONObject: requestDocument, options: [.prettyPrinted, .sortedKeys]
        )
        try data.write(to: request.appendingPathComponent("request.json"))
        return requestID
    }

    func outboxRequest(_ id: UUID) -> URL {
        vault.appendingPathComponent(
            "restore-outbox/screen-simulation/\(id.uuidString.lowercased()).bhrestore",
            isDirectory: true
        )
    }

    func processingRequest(_ id: UUID) -> URL {
        vault.appendingPathComponent(
            "restore-processing/screen-simulation/\(id.uuidString.lowercased()).bhrestore",
            isDirectory: true
        )
    }

    func quarantineRequest(_ id: UUID) -> URL {
        vault.appendingPathComponent(
            "restore-quarantine/screen-simulation/\(id.uuidString.lowercased()).bhrestore",
            isDirectory: true
        )
    }

    func result(_ id: UUID) throws -> [String: Any] {
        try json(vault.appendingPathComponent(
            "restore-results/screen-simulation/\(id.uuidString.lowercased()).json"
        ))
    }

    func json(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
