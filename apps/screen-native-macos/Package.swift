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
        .package(
            url: "https://github.com/jtorrens/StudioVideoOutput.git",
            exact: "0.1.0"
        ),
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
                .product(
                    name: "StudioVideoOutput",
                    package: "StudioVideoOutput"
                ),
                "ScreenPhysicalBridge",
            ],
            resources: [
                .copy("Resources/DeviceStage.metal"),
            ]
        ),
        .testTarget(
            name: "ScreenSimulationNativeTests",
            dependencies: [
                "ScreenSimulationNative",
                .product(
                    name: "StudioVideoOutput",
                    package: "StudioVideoOutput"
                ),
            ]
        ),
    ]
)
