// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SuperBot",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "SuperBotCore", targets: ["SuperBotCore"]),
        .executable(name: "SuperBot", targets: ["SuperBot"]),
        .executable(name: "SuperBotMessenger", targets: ["SuperBotMessenger"])
    ],
    targets: [
        .target(name: "SuperBotCore"),
        .target(name: "SuperBotSharing", dependencies: ["SuperBotCore"]),
        .executableTarget(
            name: "SuperBotShareExtension",
            dependencies: ["SuperBotSharing"],
            swiftSettings: [.unsafeFlags(["-parse-as-library", "-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        .executableTarget(
            name: "SuperBot",
            dependencies: ["SuperBotCore", "SuperBotSharing"],
            swiftSettings: [
                .unsafeFlags([
                    "-emit-const-values",
                    "-Xfrontend", "-const-gather-protocols-file",
                    "-Xfrontend", "Support/AppIntentsProtocols.json"
                ])
            ]
        ),
        .executableTarget(
            name: "SuperBotMessenger",
            dependencies: ["SuperBotCore"]
        ),
        .testTarget(
            name: "SuperBotCoreTests",
            dependencies: ["SuperBotCore"]
        )
    ],
    swiftLanguageModes: [.v5]
)
