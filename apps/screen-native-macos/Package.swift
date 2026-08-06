// swift-tools-version: 6.1

import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repositoryRoot = packageDirectory.deletingLastPathComponent().deletingLastPathComponent()
let rustLibraryDirectory = repositoryRoot.appendingPathComponent("target/debug").path
let rustReleaseLibraryDirectory = repositoryRoot.appendingPathComponent("target/release").path

let package = Package(
    name: "ScreenSimulationNative",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../packages/StudioColor"),
        .package(path: "../../packages/StudioMedia"),
    ],
    targets: [
        .target(
            name: "ScreenPhysicalBridge",
            path: "Sources/ScreenPhysicalBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags(["-L", rustReleaseLibraryDirectory, "-L", rustLibraryDirectory]),
                .linkedLibrary("screen_native_bridge"),
            ]
        ),
        .executableTarget(
            name: "ScreenSimulationNative",
            dependencies: [
                .product(name: "StudioColor", package: "StudioColor"),
                .product(name: "StudioMedia", package: "StudioMedia"),
                "ScreenPhysicalBridge",
            ]
        ),
        .testTarget(
            name: "ScreenSimulationNativeTests",
            dependencies: ["ScreenSimulationNative"]
        ),
    ]
)
