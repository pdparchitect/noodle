// swift-tools-version: 6.0

import PackageDescription
import Foundation

/// Development hooks are compiled into debug builds, and into any build made with NOODLE_DEV_HOOKS=1.
/// A release has none; scripts/verify-launch-hooks.sh checks.
let developmentHooks: [SwiftSetting] = [.define("NOODLE_DEV_HOOKS", .when(configuration: .debug))]
    + (Context.environment["NOODLE_DEV_HOOKS"] == "1" ? [.define("NOODLE_DEV_HOOKS")] : [])

/// The three targets of a tool in Tools/NAME: its provider, the extension that hosts it and its tests.
/// See Tools/AGENTS.md.
func tool(_ name: String, dependencies: [Target.Dependency] = []) -> [Target] {
    let provider = "Noodle\(name)Tools", folder = "Tools/\(name)"
    return [
        .target(name: provider, dependencies: ["NoodleCore"] + dependencies, path: "\(folder)/Sources/\(provider)"),
        .executableTarget(
            name: provider + "Extension",
            dependencies: ["NoodleCore", .target(name: provider)],
            path: "\(folder)/Sources/\(provider)Extension",
            swiftSettings: [.unsafeFlags(["-parse-as-library", "-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        .testTarget(name: provider + "Tests", dependencies: [.target(name: provider), "NoodleCore"] + dependencies,
                    path: "\(folder)/Tests/\(provider)Tests")
    ]
}

/// A built-in tool has only a provider and its tests: it runs inside Noodle rather than in
/// an extension. Calendar is built in because macOS never grants calendar access to a
/// background app extension, only to the app the person sees. See Tools/AGENTS.md.
func builtInTool(_ name: String, dependencies: [Target.Dependency] = []) -> [Target] {
    let provider = "Noodle\(name)Tools", folder = "Tools/\(name)"
    return [
        .target(name: provider, dependencies: ["NoodleCore"] + dependencies, path: "\(folder)/Sources/\(provider)"),
        .testTarget(name: provider + "Tests", dependencies: [.target(name: provider), "NoodleCore"] + dependencies,
                    path: "\(folder)/Tests/\(provider)Tests")
    ]
}

let package = Package(
    name: "Noodle",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .library(name: "NoodleCore", targets: ["NoodleCore"]),
        .library(name: "NoodleRuntime", targets: ["NoodleRuntime"]),
        .library(name: "NoodleRuntimeSettings", targets: ["NoodleRuntimeSettings"]),
        .library(name: "NoodleAgentBridge", targets: ["NoodleAgentBridge"]),
        .library(name: "NoodleToolScripting", targets: ["NoodleToolScripting"]),
        .library(name: "NoodleAppleRuntime", targets: ["NoodleAppleRuntime"]),
        .executable(name: "Noodle", targets: ["Noodle"]),
        .executable(name: "NoodleMessenger", targets: ["NoodleMessenger"])
    ],
    dependencies: [
        .package(path: "Shared/LaunchChecks"),
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
        .target(name: "NoodleCore", dependencies: [.product(name: "BrowserBridge", package: "BrowserProtocol"), .product(name: "AppletBridge", package: "Protocol"), .product(name: "ComputerBridge", package: "Bridge"), .product(name: "NoodleWallpaperCore", package: "Wallpaper")],
            swiftSettings: developmentHooks),
        .target(name: "NoodleMCP", dependencies: ["NoodleCore", .product(name: "MCP", package: "swift-sdk")]),
        .target(name: "NoodleToolScripting", dependencies: ["NoodleCore"]),
        .target(name: "NoodleSharing", dependencies: ["NoodleCore"]),
        /// Runs bots: harness processes, their discovery probes and message delivery. Shared by the
        /// apps that host bots, with none of their interface.
        .target(name: "NoodleRuntime", dependencies: ["NoodleCore", "NoodleAgentBridge"], swiftSettings: developmentHooks),
        /// The Harness, Heartbeat and Sandbox settings, shared by the apps that run bots.
        .target(name: "NoodleRuntimeSettings",
                dependencies: ["NoodleCore", "NoodleRuntime", .product(name: "NoodleSettingsUI", package: "SettingsUI"),
                               .product(name: "NoodleWallpaper", package: "Wallpaper"), "NoodleComputerTools", "NoodleMCP",
                               .product(name: "ComputerBridge", package: "Bridge"), .product(name: "AppletBridge", package: "Protocol"),
                               .product(name: "BrowserBridge", package: "BrowserProtocol"), .product(name: "Sparkle", package: "Sparkle")],
                swiftSettings: developmentHooks),
        .executableTarget(
            name: "NoodleShareExtension",
            dependencies: ["NoodleSharing"],
            swiftSettings: [.unsafeFlags(["-parse-as-library", "-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        .executableTarget(
            name: "Noodle",
            dependencies: [.product(name: "BrowserBridge", package: "BrowserProtocol"), "NoodleCore", "NoodleBrowserTools", "NoodleCalendarTools", "NoodleComputerTools", "NoodleRemindersTools", "NoodleMCP", "NoodleSharing", "NoodleRuntime", "NoodleRuntimeSettings", "NoodleAgentBridge", "NoodleAudioCapture", .product(name: "NoodleLaunchChecks", package: "LaunchChecks"), .product(name: "NoodleSettingsUI", package: "SettingsUI"), .product(name: "NoodleWallpaper", package: "Wallpaper"), .product(name: "Sparkle", package: "Sparkle"), .product(name: "ComputerBridge", package: "Bridge")],
            swiftSettings: [
                .unsafeFlags([
                    "-emit-const-values",
                    "-Xfrontend", "-const-gather-protocols-file",
                    "-Xfrontend", "Support/AppIntentsProtocols.json"
                ])
            ] + developmentHooks,
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(
            name: "NoodleMessenger",
            dependencies: ["NoodleCore", "NoodleToolScripting"]
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
            dependencies: ["Noodle", "NoodleCore", "NoodleRuntime", "NoodleRuntimeSettings", "NoodleMCP", "NoodleAudioCapture", .product(name: "NoodleLaunchChecks", package: "LaunchChecks")],
            swiftSettings: developmentHooks
        ),
        .testTarget(
            name: "NoodleComputerIntegrationTests",
            dependencies: ["Noodle", "NoodleCore", "NoodleComputerTools", .product(name: "ComputerBridge", package: "Bridge")]
        ),
        .testTarget(
            name: "NoodleSharingTests",
            dependencies: ["NoodleSharing", "NoodleCore"]
        ),
        .testTarget(name: "NoodleToolScriptingTests", dependencies: ["NoodleToolScripting", "NoodleCore"]),
        .testTarget(
            name: "NoodleMCPTests",
            dependencies: ["NoodleMCP", "NoodleCore", .product(name: "MCP", package: "swift-sdk")]
        )
    ],
    swiftLanguageModes: [.v5]
)

package.targets += tool("Vision")
    + builtInTool("Calendar")
    + builtInTool("Reminders")
    + tool("Browser", dependencies: [.product(name: "BrowserBridge", package: "BrowserProtocol")])
    + tool("Computer", dependencies: [.product(name: "ComputerBridge", package: "Bridge")])

// A newer CLT SDK can build the isolated Apple helper while an older full
// Xcode builds SwiftUI and packages the app. Keep their compiler outputs apart.
if ProcessInfo.processInfo.environment["NOODLE_APPLE_HARNESS_ONLY"] == "1" {
    let targets: Set<String> = ["NoodleCore", "NoodleAppleRuntime", "NoodleAppleAgent",
                               "NoodleMessenger", "NoodleToolScripting", "NoodleCoreTests", "NoodleAppleRuntimeTests"]
    package.targets.removeAll { !targets.contains($0.name) }
    package.products.removeAll { !["NoodleCore", "NoodleMessenger"].contains($0.name) }
}
