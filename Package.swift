// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Noodle",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "NoodleCore", targets: ["NoodleCore"]),
        .executable(name: "Noodle", targets: ["Noodle"]),
        .executable(name: "NoodleMessenger", targets: ["NoodleMessenger"]),
        .executable(name: "NoodleDocumentation", targets: ["NoodleDocumentation"])
    ],
    dependencies: [
        .package(path: "Computer/Bridge"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.1")
    ],
    targets: [
        .target(name: "NoodleAgentBridge"),
        .executableTarget(name: "NoodleAgentHost", dependencies: ["NoodleCore", "NoodleAgentBridge"]),
        .target(name: "NoodleCore", dependencies: [.product(name: "ComputerBridge", package: "Bridge")]),
        .executableTarget(name: "NoodleComputerCLI", dependencies: ["NoodleCore", .product(name: "ComputerBridge", package: "Bridge")]),
        .target(name: "NoodleMCP", dependencies: ["NoodleCore", .product(name: "MCP", package: "swift-sdk")]),
        .executableTarget(name: "NoodleMCPCLI", dependencies: ["NoodleCore"]),
        .executableTarget(name: "NoodleDocumentation", dependencies: ["NoodleCore"]),
        .target(name: "NoodleSharing", dependencies: ["NoodleCore"]),
        .executableTarget(
            name: "NoodleShareExtension",
            dependencies: ["NoodleSharing"],
            swiftSettings: [.unsafeFlags(["-parse-as-library", "-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        .executableTarget(
            name: "Noodle",
            dependencies: ["NoodleCore", "NoodleMCP", "NoodleSharing", "NoodleAgentBridge", .product(name: "Sparkle", package: "Sparkle"), .product(name: "ComputerBridge", package: "Bridge"), .product(name: "SwiftTerm", package: "SwiftTerm")],
            swiftSettings: [
                .unsafeFlags([
                    "-emit-const-values",
                    "-Xfrontend", "-const-gather-protocols-file",
                    "-Xfrontend", "Support/AppIntentsProtocols.json"
                ])
            ],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(
            name: "NoodleMessenger",
            dependencies: ["NoodleCore"]
        ),
        .testTarget(
            name: "NoodleCoreTests",
            dependencies: ["NoodleCore"]
        ),
        .testTarget(
            name: "NoodleMCPTests",
            dependencies: ["NoodleMCP", "NoodleCore", .product(name: "MCP", package: "swift-sdk")]
        )
    ],
    swiftLanguageModes: [.v5]
)
