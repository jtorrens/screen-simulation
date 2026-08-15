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

    let calibration = try EnvironmentAssetCalibration(
        inputTransformID: "linear-rec709",
        sourceUnitRadianceCandelasPerSquareMeter: 100,
        exposureEV: -1
    )
    try EnvironmentAssetLibrary.saveCalibration(calibration, for: first)
    #expect(try EnvironmentAssetLibrary.calibration(for: first) == calibration)
}

@Test func workingGeneratedEnvironmentOverwritesOneStableAsset() throws {
    let testRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("screen-generated-environment-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: testRoot) }

    let data = Data([0x76, 0x2f, 0x31, 0x01, 0x02, 0x03])
    let first = try EnvironmentAssetLibrary.storeGeneratedEXR(
        data, suggestedName: "Reflejos creados", libraryRoot: testRoot
    )
    let replacement = Data([0x76, 0x2f, 0x31, 0x04, 0x05, 0x06])
    let second = try EnvironmentAssetLibrary.storeGeneratedEXR(
        replacement, suggestedName: "Reflejos creados", libraryRoot: testRoot
    )

    #expect(first.url == second.url)
    #expect(first.sha256 != second.sha256)
    #expect(first.url.path.contains("/SCREEN-SIMULATION/Library/Environments/HDRI/"))
    #expect(first.url.lastPathComponent == "working-reflections.exr")
    #expect(try Data(contentsOf: first.url) == replacement)
    #expect(try EnvironmentAssetLibrary.asset(
        sha256: first.sha256,
        originalFileName: first.originalFileName,
        libraryRoot: testRoot
    ) == nil)
    #expect(try EnvironmentAssetLibrary.asset(
        sha256: second.sha256,
        originalFileName: second.originalFileName,
        libraryRoot: testRoot
    ) == second)
}
