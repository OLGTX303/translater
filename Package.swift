// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Translater",
    platforms: [.iOS(.v17)],
    products: [.library(name: "Translater", targets: ["Translater"])],
    dependencies: [
        .package(path: "Core"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
    ],
    targets: [
        .target(
            name: "Translater",
            dependencies: [
                .product(name: "TranslaterCore", package: "Core"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ],
            linkerSettings: [
                // xtool on Linux stamps LC_BUILD_VERSION sdk = deployment target (17.0), so iOS
                // runs the app in compatibility mode without Liquid Glass. lld takes the last
                // -platform_version; keep the second number in step with the xtool SDK (27.1).
                .unsafeFlags([
                    "-Xlinker", "-platform_version",
                    "-Xlinker", "ios",
                    "-Xlinker", "17.0",
                    "-Xlinker", "27.1",
                ]),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
