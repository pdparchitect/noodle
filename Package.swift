// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SuperBot",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "SuperBotCore", targets: ["SuperBotCore"]),
        .executable(name: "SuperBot", targets: ["SuperBot"])
    ],
    targets: [
        .target(name: "SuperBotCore"),
        .executableTarget(
            name: "SuperBot",
            dependencies: ["SuperBotCore"]
        ),
        .testTarget(
            name: "SuperBotCoreTests",
            dependencies: ["SuperBotCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
