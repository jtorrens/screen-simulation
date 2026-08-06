// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "StudioColor",
    platforms: [.macOS(.v14)],
    products: [.library(name: "StudioColor", targets: ["StudioColor"])],
    targets: [
        .binaryTarget(
            name: "StudioColorNativeBridge",
            path: "Vendor/StudioColorNativeBridge.xcframework"
        ),
        .target(
            name: "StudioColorABI",
            dependencies: ["StudioColorNativeBridge"],
            publicHeadersPath: "include"
        ),
        .target(
            name: "StudioColor",
            dependencies: ["StudioColorABI"],
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ColorSync"),
                .linkedFramework("IOKit"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
        .testTarget(name: "StudioColorTests", dependencies: ["StudioColor"]),
    ]
)

