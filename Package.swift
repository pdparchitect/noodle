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
        .library(name: "NoodleHubClient", targets: ["NoodleHubClient"]),
        .library(name: "NoodleEnterprise", targets: ["NoodleEnterprise"]),
        .library(name: "HubCore", targets: ["HubCore"]),
        .library(name: "HubMac", targets: ["HubMac"]),
        .library(name: "NoodleAgentBridge", targets: ["NoodleAgentBridge"]),
        .library(name: "NoodleToolScripting", targets: ["NoodleToolScripting"]),
        .library(name: "NoodleAppleRuntime", targets: ["NoodleAppleRuntime"]),
        .library(name: "NoodleToolConnections", targets: ["NoodleToolConnections"]),
        .library(name: "NoodleSharing", targets: ["NoodleSharing"]),
        .library(name: "NoodleAudioCapture", targets: ["NoodleAudioCapture"]),
        .library(name: "NoodleVoicePeer", targets: ["NoodleVoicePeer"]),
        .library(name: "NoodleBrowserTools", targets: ["NoodleBrowserTools"]),
        .library(name: "NoodleAppletTools", targets: ["NoodleAppletTools"]),
        .library(name: "NoodleCalendarTools", targets: ["NoodleCalendarTools"]),
        .library(name: "NoodleContextFieldsTools", targets: ["NoodleContextFieldsTools"]),
        .library(name: "NoodleComputerTools", targets: ["NoodleComputerTools"]),
        .library(name: "NoodleRemindersTools", targets: ["NoodleRemindersTools"]),
        .library(name: "NoodleImagesTools", targets: ["NoodleImagesTools"]),
        .library(name: "NoodleVisionTools", targets: ["NoodleVisionTools"]),
        .library(name: "NoodleMapsTools", targets: ["NoodleMapsTools"]),
        .executable(name: "Noodle", targets: ["Noodle"]),
        .executable(name: "NoodleMessenger", targets: ["NoodleMessenger"]),
        // A developer tool for trying catalogue tools against their services; no app includes it.
        .library(name: "NoodleToolProbe", targets: ["NoodleToolProbe"]),
        .executable(name: "noodle-tool-probe", targets: ["NoodleToolProbeCommand"])
    ],
    dependencies: [
        .package(path: "Shared/LaunchChecks"),
        .package(path: "Shared/SettingsUI"),
        .package(path: "Shared/HubLink"),
        .package(path: "Shared/Wallpaper"),
        .package(path: "Shared/Brand"),
        .package(path: "Shared/Patch"),
        .package(path: "Shared/Document"),
        .package(path: "Computer/Bridge"),
        .package(path: "Applet/Protocol"),
        .package(path: "Browser/BrowserProtocol"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.33.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift", .upToNextMinor(from: "0.33.0")),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.4"),
        .package(path: "Shared/Product"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk", exact: "0.12.1"),
        // CryptoKit's API where there is no CryptoKit.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "6.0.0"),
        // WebRTC for calls, built with a custom audio device, which Google's own Apple builds lack on macOS.
        .package(url: "https://github.com/livekit/webrtc-xcframework", exact: "150.7871.03")
    ],
    targets: [
        .target(name: "NoodleAgentBridge", dependencies: [.product(name: "ProductIdentity", package: "Product")]),
        .target(name: "NoodleAudioCapture", cSettings: [.unsafeFlags(["-fobjc-arc"])]),
        .executableTarget(name: "NoodleAgentHost", dependencies: ["NoodleCore", "NoodleAgentBridge", .product(name: "ProductIdentity", package: "Product")]),
        .target(name: "NoodleAppleRuntime", dependencies: ["NoodleCore",
            .product(name: "MLXFoundationModels", package: "mlx-swift-lm"),
            .product(name: "MLXLLM", package: "mlx-swift-lm"),
            "StableDiffusion",
            .product(name: "Tokenizers", package: "swift-transformers")],
            exclude: ["FoundationModelsUtilities/AGENTS.md", "FoundationModelsUtilities/CLAUDE.md"]),
        /// Stable Diffusion XL in MLX, for the Images tool: a copy of Libraries/StableDiffusion from
        /// github.com/ml-explore/mlx-swift-examples at ef1084dd5692611a8758b24b07efdad5404ac3ce, MIT
        /// licensed (Support/ThirdParty/StableDiffusion), changed to load from a local model folder.
        .target(name: "StableDiffusion", dependencies: [.product(name: "MLX", package: "mlx-swift"),
                                                        .product(name: "MLXNN", package: "mlx-swift")]),
        .executableTarget(name: "NoodleAppleAgent", dependencies: ["NoodleAppleRuntime", "NoodleCore"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                                         "-Xlinker", "Support/AppleAgent-Info.plist"])]),
        /// The system's SQLite where the SDK has no module for it.
        .systemLibrary(name: "CSQLite", providers: [.apt(["libsqlite3-dev"])]),
        .target(name: "NoodleCore", dependencies: [.target(name: "CSQLite", condition: .when(platforms: [.linux])), .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])), .product(name: "ProductIdentity", package: "Product"), .product(name: "BrowserBridge", package: "BrowserProtocol"), .product(name: "AppletBridge", package: "Protocol"), .product(name: "ComputerBridge", package: "Bridge"), .product(name: "NoodleWallpaperCore", package: "Wallpaper"), .product(name: "NoodlePatch", package: "Patch")],
            swiftSettings: developmentHooks),
        /// Noodle Enterprise: managed preferences from a configuration profile. Source-available under
        /// Enterprise/LICENSE, not the Functional Source License; the rest of Noodle reaches it only
        /// through NoodleCore's OrganisationPolicy.
        .target(name: "NoodleEnterprise", dependencies: ["NoodleCore"], path: "Enterprise/Sources/NoodleEnterprise"),
        .executableTarget(name: "NoodleEnterpriseFiles", dependencies: ["NoodleEnterprise"], path: "Enterprise/Sources/NoodleEnterpriseFiles"),
        .testTarget(name: "NoodleEnterpriseTests", dependencies: ["NoodleEnterprise", "NoodleCore"], path: "Enterprise/Tests/NoodleEnterpriseTests"),
        .target(name: "NoodleWidgets", dependencies: ["NoodleCore", .product(name: "NoodleWallpaper", package: "Wallpaper")],
                exclude: ["NoodleWidgetsBundle.swift"]),
        .testTarget(name: "NoodleWidgetsTests", dependencies: ["NoodleWidgets", "NoodleCore"]),
        .target(name: "NoodleToolConnections", dependencies: ["NoodleCore", .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])), .product(name: "ProductIdentity", package: "Product"), .product(name: "MCP", package: "swift-sdk")]),
        .target(name: "NoodleToolScripting", dependencies: ["NoodleCore"]),
        .target(name: "NoodleToolProbe", dependencies: ["NoodleCore", "NoodleToolConnections"]),
        .executableTarget(name: "NoodleToolProbeCommand", dependencies: ["NoodleCore", "NoodleToolProbe"]),
        .target(name: "NoodleSharing", dependencies: ["NoodleCore", .product(name: "ProductIdentity", package: "Product")]),
        /// Runs bots: harness processes, their discovery probes and message delivery. Shared by the
        /// apps that host bots, with none of their interface.
        .target(name: "NoodleRuntime", dependencies: ["NoodleCore", "NoodleAgentBridge", .product(name: "ProductIdentity", package: "Product"), .product(name: "AppletBridge", package: "Protocol")],
                swiftSettings: developmentHooks),
        /// The Harness, Heartbeat and Sandbox settings, shared by the apps that run bots.
        .target(name: "NoodleHubClient", dependencies: ["NoodleCore", .product(name: "HubLink", package: "HubLink")]),
        /// Calls' WebRTC connection to a harness's voice service, fed and played by whoever holds the call.
        .target(name: "NoodleVoicePeer", dependencies: ["NoodleCore", .product(name: "LiveKitWebRTC", package: "webrtc-xcframework")]),
        /// What serves paired devices: Noodle Hub for the people it lends to, and Noodle for its own owner.
        .target(name: "HubCore", dependencies: ["NoodleCore", "NoodleRuntime", "NoodleToolConnections", .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
                                                .product(name: "AppletBridge", package: "Protocol"),
                                                .product(name: "HubWire", package: "HubLink")]),
        /// HubCore on a Mac: with Noodle Computer, Browser and Applet, image generation, calls and CloudKit.
        .target(name: "HubMac", dependencies: ["HubCore", "NoodleCore", "NoodleRuntime", "NoodleVoicePeer", "NoodleToolConnections", "NoodleAppletTools", "NoodleComputerTools", "NoodleBrowserTools", "NoodleImagesTools",
                                               .product(name: "ComputerBridge", package: "Bridge"),
                                               .product(name: "BrowserBridge", package: "BrowserProtocol"),
                                               .product(name: "AppletBridge", package: "Protocol"),
                                               .product(name: "HubLink", package: "HubLink")]),
        .target(name: "NoodleRuntimeSettings",
                dependencies: ["NoodleCore", "NoodleRuntime", "HubCore", "HubMac", .product(name: "NoodleSettingsUI", package: "SettingsUI"),
                               .product(name: "NoodleWallpaper", package: "Wallpaper"), "NoodleComputerTools", "NoodleToolConnections",
                               .product(name: "ComputerBridge", package: "Bridge"), .product(name: "AppletBridge", package: "Protocol"),
                               .product(name: "BrowserBridge", package: "BrowserProtocol"), .product(name: "Sparkle", package: "Sparkle"),
                               .product(name: "NoodleBrand", package: "Brand")],
                swiftSettings: developmentHooks),
        .executableTarget(
            name: "NoodleShareExtension",
            dependencies: ["NoodleSharing"],
            swiftSettings: [.unsafeFlags(["-parse-as-library", "-application-extension"])],
            linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]
        ),
        .executableTarget(
            name: "Noodle",
            dependencies: [.product(name: "BrowserBridge", package: "BrowserProtocol"), "NoodleCore", "NoodleAppletTools", "NoodleBrowserTools", "NoodleCalendarTools", "NoodleComputerTools", "NoodleContextFieldsTools", "NoodleImagesTools", "NoodleRemindersTools", "NoodleToolConnections", "NoodleSharing", "NoodleRuntime", "NoodleRuntimeSettings", "NoodleAgentBridge", "NoodleAudioCapture", "NoodleVoicePeer", "HubCore", "HubMac", .product(name: "NoodleLaunchChecks", package: "LaunchChecks"), .product(name: "NoodleSettingsUI", package: "SettingsUI"), .product(name: "NoodleWallpaper", package: "Wallpaper"), .product(name: "NoodleDocument", package: "Document"), .product(name: "NoodleBrand", package: "Brand"), .product(name: "Sparkle", package: "Sparkle"), .product(name: "ComputerBridge", package: "Bridge"), .product(name: "HubLink", package: "HubLink"), "NoodleHubClient", "NoodleEnterprise", .product(name: "NoodletRuntime", package: "Protocol")],
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
            dependencies: ["NoodleCore", .product(name: "ProductIdentity", package: "Product")]
        ),
        /// NoodleCore's tests that also run on Linux.
        .testTarget(name: "NoodleCorePortableTests", dependencies: ["NoodleCore"]),
        /// The tool connections' tests that also run on Linux.
        .testTarget(name: "NoodleToolConnectionsPortableTests", dependencies: ["NoodleToolConnections", "NoodleCore"]),
        .testTarget(
            name: "NoodleAppTests",
            dependencies: ["Noodle", "NoodleContextFieldsTools", "NoodleCore", "NoodleRuntime", "NoodleVoicePeer", "NoodleRuntimeSettings", "NoodleToolConnections", "NoodleAudioCapture", .product(name: "NoodleLaunchChecks", package: "LaunchChecks"), .product(name: "HubLink", package: "HubLink"), "NoodleHubClient", "HubCore", "HubMac", .product(name: "NoodleBrand", package: "Brand"), .product(name: "NoodletRuntime", package: "Protocol")],
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
        .testTarget(name: "NoodleAgentBridgeTests", dependencies: ["NoodleAgentBridge"]),
        .testTarget(
            name: "HubCoreTests",
            dependencies: ["HubCore", "HubMac", "NoodleCore", "NoodleHubClient", "NoodleToolConnections", "NoodleRuntime", "NoodleVoicePeer", .product(name: "HubLink", package: "HubLink"),
                           .product(name: "ComputerBridge", package: "Bridge"), .product(name: "BrowserBridge", package: "BrowserProtocol"),
                           .product(name: "AppletBridge", package: "Protocol")]
        ),
        .testTarget(
            name: "NoodleToolConnectionsTests",
            dependencies: ["NoodleToolConnections", "NoodleCore", .product(name: "MCP", package: "swift-sdk")]
        )
    ],
    swiftLanguageModes: [.v5]
)

package.targets += tool("Vision")
    + tool("Maps")
    + builtInTool("Calendar")
    + builtInTool("ContextFields")
    + builtInTool("Applet", dependencies: [.product(name: "AppletBridge", package: "Protocol")])
    + builtInTool("Reminders")
    + builtInTool("Images")
    + tool("Browser", dependencies: [.product(name: "BrowserBridge", package: "BrowserProtocol")])
    + tool("Computer", dependencies: [.product(name: "ComputerBridge", package: "Bridge")])

// Only the Apple harness and its tests, for CI's macOS 27 job; the app is tested separately.
if ProcessInfo.processInfo.environment["NOODLE_APPLE_HARNESS_ONLY"] == "1" {
    // CSQLite stays declared, since NoodleCore names it, though only Linux builds it.
    let targets: Set<String> = ["CSQLite", "NoodleCore", "NoodleAppleRuntime", "StableDiffusion", "NoodleAppleAgent",
                               "NoodleMessenger", "NoodleToolScripting", "NoodleCoreTests", "NoodleAppleRuntimeTests"]
    package.targets.removeAll { !targets.contains($0.name) }
    package.products.removeAll { !["NoodleCore", "NoodleMessenger"].contains($0.name) }
}

#if os(Linux)
// Only the Hub engine builds on Linux, with the tests that run there.
let linux: Set<String> = ["CSQLite", "NoodleCore", "NoodleToolConnections", "NoodleAgentBridge", "NoodleRuntime", "HubCore", "NoodleCorePortableTests", "NoodleToolConnectionsPortableTests"]
package.targets.removeAll { !linux.contains($0.name) }
package.products.removeAll { !["NoodleCore", "NoodleToolConnections", "NoodleAgentBridge", "NoodleRuntime", "HubCore"].contains($0.name) }
#endif
