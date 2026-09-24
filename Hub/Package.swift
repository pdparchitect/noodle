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
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
    ],
    targets: [
        .target(
            name: "HubCore",
            dependencies: [
                .product(name: "NoodleCore", package: "noodle"),
                .product(name: "NoodleRuntime", package: "noodle"),
            ]),
        .executableTarget(
            name: "NoodleHub",
            dependencies: [
                "HubCore",
                .product(name: "NoodleRuntimeSettings", package: "noodle"),
                .product(name: "NoodleSettingsUI", package: "SettingsUI"),
                .product(name: "Sparkle", package: "Sparkle"),
            ]),
        .testTarget(name: "HubCoreTests", dependencies: ["HubCore"]),
    ],
    swiftLanguageModes: [.v5]
)
