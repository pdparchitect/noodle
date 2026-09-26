// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NoodleHub",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "NoodleHub", targets: ["NoodleHub"]),
        .library(name: "HubCore", targets: ["HubCore"]),
    ],
    dependencies: [
        // Noodle itself: the Hub runs bots with the same runtime.
        .package(path: ".."),
        .package(path: "../Shared/SettingsUI"),
        .package(path: "../Shared/HubLink"),
        .package(path: "../Computer/Bridge"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
    ],
    targets: [
        .target(
            name: "HubCore",
            dependencies: [
                .product(name: "NoodleCore", package: "noodle"),
                .product(name: "NoodleRuntime", package: "noodle"),
                .product(name: "NoodleMCP", package: "noodle"),
                .product(name: "NoodleComputerTools", package: "noodle"),
                .product(name: "ComputerBridge", package: "Bridge"),
                .product(name: "HubLink", package: "HubLink"),
            ]),
        .executableTarget(
            name: "NoodleHub",
            dependencies: [
                "HubCore",
                .product(name: "HubLink", package: "HubLink"),
                .product(name: "NoodleRuntimeSettings", package: "noodle"),
                .product(name: "NoodleSettingsUI", package: "SettingsUI"),
                .product(name: "Sparkle", package: "Sparkle"),
            ]),
        .testTarget(name: "HubCoreTests", dependencies: ["HubCore", .product(name: "NoodleCore", package: "noodle"),
                                                        .product(name: "HubLink", package: "HubLink"),
                                                        .product(name: "NoodleHubClient", package: "noodle"),
                                                        .product(name: "NoodleMCP", package: "noodle"),
                                                        .product(name: "ComputerBridge", package: "Bridge")]),
    ],
    swiftLanguageModes: [.v5]
)
