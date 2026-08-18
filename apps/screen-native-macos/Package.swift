// swift-tools-version: 6.1

import Foundation
import PackageDescription

let packageDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repositoryRoot = packageDirectory.deletingLastPathComponent().deletingLastPathComponent()
let rustLibraryDirectory = repositoryRoot.appendingPathComponent("target/debug").path
let rustReleaseLibraryDirectory = repositoryRoot.appendingPathComponent("target/release").path
let ffmpegLibraryDirectory = "/opt/homebrew/opt/ffmpeg/lib"

let package = Package(
    name: "ScreenSimulationNative",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../../packages/StudioColor"),
        .package(path: "../../packages/StudioMedia"),
        .package(
            url: "https://github.com/jtorrens/StudioVideoOutput.git",
            exact: "0.2.0"
        ),
    ],
    targets: [
        .target(
            name: "ScreenSimulationPresentation"
        ),
        .target(
            name: "ScreenSimulationMacUI",
            dependencies: ["ScreenSimulationPresentation"]
        ),
        .target(
            name: "ScreenPhysicalBridge",
            path: "Sources/ScreenPhysicalBridge",
            publicHeadersPath: "include",
            linkerSettings: [
                .unsafeFlags([
                    "-L", rustReleaseLibraryDirectory,
                    "-L", rustLibraryDirectory,
                    "-L", ffmpegLibraryDirectory,
                    "-lavformat", "-lavcodec", "-lswscale", "-lavutil",
                ]),
                .linkedLibrary("screen_native_bridge"),
            ]
        ),
        .executableTarget(
            name: "ScreenSimulationNative",
            dependencies: [
                "ScreenSimulationPresentation",
                "ScreenSimulationMacUI",
                .product(name: "StudioColor", package: "StudioColor"),
                .product(name: "StudioMedia", package: "StudioMedia"),
                .product(
                    name: "StudioVideoOutput",
                    package: "StudioVideoOutput"
                ),
                "ScreenPhysicalBridge",
            ]
        ),
        .testTarget(
            name: "ScreenSimulationPresentationTests",
            dependencies: ["ScreenSimulationPresentation"]
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
