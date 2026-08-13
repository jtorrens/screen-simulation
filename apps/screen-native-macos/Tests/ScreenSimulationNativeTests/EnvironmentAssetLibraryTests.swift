import Foundation
import Testing
@testable import ScreenSimulationNative

@Test func environmentLibraryUsesAStableContentAddressedApplicationSupportPath() throws {
    let testRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-environment-library-\(UUID().uuidString)")
    let temporary = testRoot
        .appendingPathComponent("screen-environment-\(UUID().uuidString).exr")
    try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: testRoot) }
    try Data([1, 2, 3, 4]).write(to: temporary)

    let first = try EnvironmentAssetLibrary.importAsset(from: temporary, libraryRoot: testRoot)
    let second = try EnvironmentAssetLibrary.importAsset(from: temporary, libraryRoot: testRoot)

    #expect(first == second)
    #expect(first.originalFileName == temporary.lastPathComponent)
    #expect(first.url.path.contains("/SCREEN-SIMULATION/Library/Environments/HDRI/"))
    #expect(first.url.lastPathComponent ==
        "\(temporary.deletingPathExtension().lastPathComponent)--\(first.sha256).exr")
    #expect(try EnvironmentAssetLibrary.asset(
        sha256: first.sha256,
        originalFileName: first.originalFileName,
        libraryRoot: testRoot
    ) == first)
}
