// swift-tools-version: 6.2
import PackageDescription
// The provider and Noodle share the versioned Computer/Bridge protocol.

// Development-only launch checks are compiled into debug builds, and into release builds that ask for them.
var appSettings: [SwiftSetting] = [.define("NOODLE_DEV_HOOKS", .when(configuration: .debug))]
if Context.environment["NOODLE_DEV_HOOKS"] == "1" { appSettings.append(.define("NOODLE_DEV_HOOKS")) }

let package = Package(
    name: "NoodleComputer",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "NoodleComputer", targets: ["NoodleComputer"]),
        .library(name: "ComputerCore", targets: ["ComputerCore"])],
    dependencies: [
        .package(path: "../Shared/LaunchChecks"),
        .package(path: "../Shared/SettingsUI"),
        .package(path: "../Shared/Wallpaper"),
        .package(path: "Bridge"),
        .package(path: "LocalMac"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
        .package(url: "https://github.com/apple/containerization.git", exact: "0.43.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")
    ],
    targets: [
        .target(name: "ComputerCore", dependencies: [.product(name: "NoodleWallpaperCore", package: "Wallpaper")], resources: [.process("Resources")]),
        .executableTarget(name: "NoodleComputer", dependencies: [
            "ComputerCore",
            .product(name: "NoodleLaunchChecks", package: "LaunchChecks"),
            .product(name: "NoodleSettingsUI", package: "SettingsUI"),
            .product(name: "NoodleWallpaper", package: "Wallpaper"),
            .product(name: "Sparkle", package: "Sparkle"),
            .product(name: "ComputerBridge", package: "Bridge"),
            .product(name: "LocalMacCore", package: "LocalMac"),
            .product(name: "SwiftTerm", package: "SwiftTerm"),
            .product(name: "Containerization", package: "containerization"),
            .product(name: "ContainerizationEXT4", package: "containerization"),
            .product(name: "ContainerizationExtras", package: "containerization"),
            .product(name: "ContainerizationOCI", package: "containerization")
        ], swiftSettings: appSettings),
        .testTarget(name: "ComputerCoreTests", dependencies: ["ComputerCore"]),
        .testTarget(name: "ComputerStorageTests", dependencies: ["NoodleComputer"])
    ],
    swiftLanguageModes: [.v5]
)
