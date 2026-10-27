// swift-tools-version: 6.0

import PackageDescription

// Platform-free core (model, timeline, pipelines, export) so `swift test` runs on Linux.
let package = Package(
    name: "TranslaterCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "TranslaterCore", targets: ["TranslaterCore"])],
    targets: [
        .target(name: "TranslaterCore"),
        .testTarget(name: "TranslaterCoreTests", dependencies: ["TranslaterCore"]),
    ],
    swiftLanguageModes: [.v5]
)
