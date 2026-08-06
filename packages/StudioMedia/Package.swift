// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "StudioMedia",
    platforms: [.macOS(.v14)],
    products: [.library(name: "StudioMedia", targets: ["StudioMedia"])],
    targets: [
        .target(name: "StudioMedia"),
        .testTarget(name: "StudioMediaTests", dependencies: ["StudioMedia"]),
    ]
)
