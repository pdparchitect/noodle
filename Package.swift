// swift-tools-version: 6.0

import PackageDescription
import Foundation

let package = Package(
    name: "Noodle",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "NoodleCore", targets: ["NoodleCore"]),
        .executable(name: "Noodle", targets: ["Noodle"]),
        .executable(name: "NoodleMessenger", targets: ["NoodleMessenger"]),
        .executable(name: "NoodleDocumentation", targets: ["NoodleDocumentation"])
    ],
    dependencies: [
        .package(path: "Shared/SettingsUI"),
        .package(path: "Shared/Wallpaper"),
        .package(path: "Computer/Bridge"),
        .package(path: "Applet/Protocol"),
        .package(path: "Browser/BrowserProtocol"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
        // The macOS 27 Foundation Models adapter is not in an MLX release yet.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", revision: "3e6ea1ede1596f05c1715d6b82567619276e98f0"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.4"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.1")
    ],
    targets: [
        .target(name: "NoodleAgentBridge"),
        .target(name: "NoodleAudioCapture", cSettings: [.unsafeFlags(["-fobjc-arc"])]),
        .executableTarget(name: "NoodleAgentHost", dependencies: ["NoodleCore", "NoodleAgentBridge"]),
        .target(name: "NoodleAppleRuntime", dependencies: ["NoodleCore",
            .product(name: "MLXFoundationModels", package: "mlx-swift-lm"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            .product(name: "Tokenizers", package: "swift-transformers")],
            exclude: ["FoundationModelsUtilities/AGENTS.md", "FoundationModelsUtilities/CLAUDE.md"]),
        .executableTarget(name: "NoodleAppleAgent", dependencies: ["NoodleAppleRuntime", "NoodleCore"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                                         "-Xlinker", "Support/AppleAgent-Info.plist"])]),
        .target(name: "NoodleCore", dependencies: [.product(name: "BrowserBridge", package: "BrowserProtocol"), .product(name: "AppletBridge", package: "Protocol"), .product(name: "ComputerBridge", package: "Bridge"), .product(name: "NoodleWallpaperCore", package: "Wallpaper")]),
        .target(name: "NoodleMCP", dependencies: ["NoodleCore", .product(name: "MCP", package: "swift-sdk")]),
        .target(name: "NoodleMCPScripting", dependencies: ["NoodleCore"]),
        .executableTarget(name: "NoodleDocumentation", dependencies: ["NoodleCore"]),
        .target(name: "NoodleSharing", dependencies: ["NoodleCore"]),
        .target(name: "NoodleVisionTools", dependencies: ["NoodleCore"]),
        .target(name: "NoodleBrowserTools", dependencies: ["NoodleCore", .product(name: "BrowserBridge", package: "BrowserProtocol")]),
        .target(name: "NoodleComputerTools", dependencies: ["NoodleCore", .product(name: "ComputerBridge", package: "Bridge")]),
        .executableTarget(
            name: "NoodleComputerToolsExtension",
            dependencies: ["NoodleCore", "NoodleComputerTools"],
            swiftSettings: [.unsafeFlags(["-parse-as-library", "-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        .executableTarget(
            name: "NoodleBrowserToolsExtension",
            dependencies: ["NoodleCore", "NoodleBrowserTools"],
            swiftSettings: [.unsafeFlags(["-parse-as-library", "-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        .executableTarget(
            name: "NoodleVisionToolsExtension",
            dependencies: ["NoodleCore", "NoodleVisionTools"],
            swiftSettings: [.unsafeFlags(["-parse-as-library", "-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        .executableTarget(
            name: "NoodleShareExtension",
            dependencies: ["NoodleSharing"],
            swiftSettings: [.unsafeFlags(["-parse-as-library", "-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        .executableTarget(
            name: "Noodle",
            dependencies: [.product(name: "BrowserBridge", package: "BrowserProtocol"), "NoodleCore", "NoodleBrowserTools", "NoodleComputerTools", "NoodleMCP", "NoodleSharing", "NoodleAgentBridge", "NoodleAudioCapture", .product(name: "NoodleSettingsUI", package: "SettingsUI"), .product(name: "NoodleWallpaper", package: "Wallpaper"), .product(name: "Sparkle", package: "Sparkle"), .product(name: "ComputerBridge", package: "Bridge")],
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
            dependencies: ["NoodleCore", "NoodleMCPScripting"]
        ),
        .testTarget(
            name: "NoodleAppleRuntimeTests",
            dependencies: ["NoodleAppleRuntime", "NoodleCore"]
        ),
        .testTarget(
            name: "NoodleCoreTests",
            dependencies: ["NoodleCore"]
        ),
        .testTarget(
            name: "NoodleAppTests",
            dependencies: ["Noodle", "NoodleCore", "NoodleMCP", "NoodleAudioCapture"]
        ),
        .testTarget(
            name: "NoodleComputerIntegrationTests",
            dependencies: ["Noodle", "NoodleCore", "NoodleComputerTools", .product(name: "ComputerBridge", package: "Bridge")]
        ),
        .testTarget(
            name: "NoodleSharingTests",
            dependencies: ["NoodleSharing", "NoodleCore"]
        ),
        .testTarget(name: "NoodleVisionToolsTests", dependencies: ["NoodleVisionTools", "NoodleCore"]),
        .testTarget(name: "NoodleComputerToolsTests", dependencies: ["NoodleComputerTools", "NoodleCore", .product(name: "ComputerBridge", package: "Bridge")]),
        .testTarget(name: "NoodleBrowserToolsTests", dependencies: ["NoodleBrowserTools", "NoodleCore", .product(name: "BrowserBridge", package: "BrowserProtocol")]),
        .testTarget(name: "NoodleMCPScriptingTests", dependencies: ["NoodleMCPScripting", "NoodleCore"]),
        .testTarget(
            name: "NoodleMCPTests",
            dependencies: ["NoodleMCP", "NoodleCore", .product(name: "MCP", package: "swift-sdk")]
        )
    ],
    swiftLanguageModes: [.v5]
)

// A newer CLT SDK can build the isolated Apple helper while an older full
// Xcode builds SwiftUI and packages the app. Keep their compiler outputs apart.
if ProcessInfo.processInfo.environment["NOODLE_APPLE_HARNESS_ONLY"] == "1" {
    let targets: Set<String> = ["NoodleCore", "NoodleAppleRuntime", "NoodleAppleAgent",
                               "NoodleMessenger", "NoodleMCPScripting", "NoodleDocumentation", "NoodleCoreTests", "NoodleAppleRuntimeTests"]
    package.targets.removeAll { !targets.contains($0.name) }
    package.products.removeAll { !["NoodleCore", "NoodleMessenger", "NoodleDocumentation"].contains($0.name) }
}
