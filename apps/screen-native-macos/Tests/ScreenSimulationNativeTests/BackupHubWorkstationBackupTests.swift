import CryptoKit
import Foundation
import Testing
@testable import ScreenSimulationNative

@Test func workstationBackupPublishesExactBackupHubPackage() throws {
    let support = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: support) }
    let inbox = try prepareVault(in: support)
    let state = support.appendingPathComponent("SCREEN-SIMULATION", isDirectory: true)
    let autosave = state.appendingPathComponent(
        "Library/Autosave.v25/scene/revision.json"
    )
    let environment = state.appendingPathComponent(
        "Library/Environments/HDRI/managed.exr"
    )
    try FileManager.default.createDirectory(
        at: autosave.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: environment.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data("autosave".utf8).write(to: autosave)
    try Data("environment".utf8).write(to: environment)
    try Data("legacy".utf8).write(
        to: state.appendingPathComponent("GlobalLibrary.v16.json")
    )
    try Data("migration".utf8).write(
        to: state.appendingPathComponent("GlobalLibrary.v17.backup-previous.json")
    )

    let packageID = try #require(UUID(uuidString: "550e8400-e29b-41d4-a716-446655440000"))
    let producer = try BackupHubWorkstationProducer(
        applicationSupportURL: support,
        producerVersion: { "9.8.7" },
        makePackageID: { packageID },
        now: { Date(timeIntervalSince1970: 0) }
    )
    let package = try producer.publish(reason: .manual)

    #expect(package == inbox.appendingPathComponent(
        "550e8400-e29b-41d4-a716-446655440000.bhpkg"
    ))
    #expect(!FileManager.default.fileExists(
        atPath: inbox.appendingPathComponent(".550e8400-e29b-41d4-a716-446655440000.tmp").path
    ))
    let manifestData = try Data(contentsOf: package.appendingPathComponent("manifest.json"))
    let manifest = try #require(
        JSONSerialization.jsonObject(with: manifestData) as? [String: Any]
    )
    #expect(Set(manifest.keys) == [
        "contractVersion", "packageId", "applicationId", "createdAt", "reason",
        "producer", "snapshot", "files",
    ])
    #expect((manifest["contractVersion"] as? NSNumber)?.intValue == 1)
    #expect(manifest["packageId"] as? String == packageID.uuidString.lowercased())
    #expect(manifest["applicationId"] as? String == "screen-simulation")
    #expect(manifest["reason"] as? String == "manual")
    #expect(manifest["createdAt"] as? String == "1970-01-01T00:00:00.000Z")
    #expect(manifest["producer"] as? [String: String] == [
        "version": "9.8.7", "platform": "macos",
    ])
    #expect(manifest["snapshot"] as? [String: String] == [
        "format": "screen-simulation-workstation", "schemaVersion": "1",
    ])

    let files = try #require(manifest["files"] as? [[String: Any]])
    let paths = files.compactMap { $0["path"] as? String }
    #expect(paths == [
        "snapshot.json",
        "state/Library/Autosave.v25/scene/revision.json",
        "state/Library/Environments/HDRI/managed.exr",
    ])
    #expect(!paths.contains(where: { $0.contains("v16") || $0.contains("backup-") }))
    for file in files {
        let path = try #require(file["path"] as? String)
        let bytes = try Data(contentsOf: package.appendingPathComponent("payload/\(path)"))
        #expect((file["byteLength"] as? NSNumber)?.intValue == bytes.count)
        #expect(file["sha256"] as? String == SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }.joined())
    }

    let snapshotData = try Data(contentsOf: package.appendingPathComponent("payload/snapshot.json"))
    let snapshot = try #require(
        JSONSerialization.jsonObject(with: snapshotData) as? [String: Any]
    )
    #expect(Set(snapshot.keys) == ["schema", "includedStatePaths"])
    #expect(snapshot["schema"] as? String == "ScreenSimulation.WorkstationSnapshot.v1")
    #expect(snapshot["includedStatePaths"] as? [String] == [
        "Library/Autosave.v25/scene/revision.json",
        "Library/Environments/HDRI/managed.exr",
    ])
}

@Test func workstationBackupRequiresCanonicalVaultMarkerAndInbox() throws {
    let support = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: support) }
    let producer = try BackupHubWorkstationProducer(
        applicationSupportURL: support,
        producerVersion: { "1.0" }
    )
    #expect(throws: WorkstationBackupError.self) {
        try producer.publish(reason: .manual)
    }

    let vault = support.appendingPathComponent("com.jtorrens.backup-hub/vault")
    try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
    try Data(#"{"layoutVersion":1,"vaultId":"com.jtorrens.backup-hub","legacy":true}"#.utf8)
        .write(to: vault.appendingPathComponent("vault-layout.json"))
    try FileManager.default.createDirectory(
        at: vault.appendingPathComponent("inbox"), withIntermediateDirectories: true
    )
    #expect(throws: WorkstationBackupError.self) {
        try producer.publish(reason: .manual)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: vault.appendingPathComponent("inbox").path).isEmpty)

    try Data(#"{"layoutVersion":true,"vaultId":"com.jtorrens.backup-hub"}"#.utf8)
        .write(to: vault.appendingPathComponent("vault-layout.json"), options: .atomic)
    #expect(throws: WorkstationBackupError.self) {
        try producer.publish(reason: .manual)
    }

    try Data(#"{"layoutVersion":1.5,"vaultId":"com.jtorrens.backup-hub"}"#.utf8)
        .write(to: vault.appendingPathComponent("vault-layout.json"), options: .atomic)
    #expect(throws: WorkstationBackupError.self) {
        try producer.publish(reason: .manual)
    }
}

@Test func workstationBackupFailureLeavesNoVisibleOrTemporaryPackage() throws {
    let support = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: support) }
    let inbox = try prepareVault(in: support)
    let autosaveRoot = support.appendingPathComponent(
        "SCREEN-SIMULATION/Library/Autosave.v25", isDirectory: true
    )
    try FileManager.default.createDirectory(at: autosaveRoot, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
        at: autosaveRoot.appendingPathComponent("linked.json"),
        withDestinationURL: support.appendingPathComponent("outside.json")
    )
    let producer = try BackupHubWorkstationProducer(
        applicationSupportURL: support,
        producerVersion: { "1.0" },
        makePackageID: { UUID(uuidString: "550e8400-e29b-41d4-a716-446655440001")! }
    )

    #expect(throws: WorkstationBackupError.self) {
        try producer.publish(reason: .cleanExit)
    }
    #expect(try FileManager.default.contentsOfDirectory(atPath: inbox.path).isEmpty)
}

private func prepareVault(in support: URL) throws -> URL {
    let vault = support.appendingPathComponent("com.jtorrens.backup-hub/vault")
    let inbox = vault.appendingPathComponent("inbox")
    try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
    try Data(#"{"layoutVersion":1,"vaultId":"com.jtorrens.backup-hub"}"#.utf8)
        .write(to: vault.appendingPathComponent("vault-layout.json"))
    return inbox
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-backup-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
