// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NoodleHub",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "NoodleHub", targets: ["NoodleHub"]),
    ],
    dependencies: [
        // Noodle itself: the Hub runs bots with the same runtime.
        .package(path: ".."),
        .package(path: "../Shared/SettingsUI"),
        .package(path: "../Shared/HubLink"),
        .package(path: "../Shared/LaunchChecks"),
        .package(path: "../Computer/Bridge"),
        .package(path: "../Browser/BrowserProtocol"),
        .package(path: "../Applet/Protocol"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
    ],
    targets: [
        .executableTarget(
            name: "NoodleHub",
            dependencies: [
                .product(name: "HubCore", package: "noodle"),
                .product(name: "HubLink", package: "HubLink"),
                .product(name: "NoodleLaunchChecks", package: "LaunchChecks"),
                .product(name: "NoodleRuntimeSettings", package: "noodle"),
                .product(name: "NoodleSettingsUI", package: "SettingsUI"),
                .product(name: "Sparkle", package: "Sparkle"),
            ]),
        .testTarget(name: "HubCoreTests", dependencies: [.product(name: "HubCore", package: "noodle"), .product(name: "NoodleCore", package: "noodle"),
                                                        .product(name: "HubLink", package: "HubLink"),
                                                        .product(name: "NoodleHubClient", package: "noodle"),
                                                        .product(name: "NoodleMCP", package: "noodle"),
                                                        .product(name: "NoodleRuntime", package: "noodle"),
                                                        .product(name: "ComputerBridge", package: "Bridge"),
                                                        .product(name: "BrowserBridge", package: "BrowserProtocol"),
                                                        .product(name: "AppletBridge", package: "Protocol")]),
    ],
    swiftLanguageModes: [.v5]
)
