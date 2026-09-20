// swift-tools-version: 6.0
import PackageDescription

// Development hooks are compiled into debug builds, and into any build made with NOODLE_DEV_HOOKS=1.
var appSettings: [SwiftSetting] = [.define("NOODLE_DEV_HOOKS", .when(configuration: .debug))]
if Context.environment["NOODLE_DEV_HOOKS"] == "1" { appSettings.append(.define("NOODLE_DEV_HOOKS")) }

let package = Package(
    name: "NoodleApplet",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "NoodleApplet", targets: ["NoodleApplet"]),
        .executable(name: "noodlet", targets: ["NoodletCLI"]),
        .executable(name: "NoodletPreview", targets: ["NoodletPreview"]),
        .executable(name: "NoodletHost", targets: ["NoodletHost"]),
    ],
    dependencies: [
        .package(path: "../Shared/SettingsUI"),
        .package(path: "../Shared/LaunchChecks"),
        .package(path: "Protocol"),
        .package(path: "../Shared/Wallpaper"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
    ],
    targets: [
        .target(
            name: "AppletCore", dependencies: [.product(name: "AppletBridge", package: "Protocol")]),
        .executableTarget(
            name: "NoodleApplet",
            dependencies: [
                "AppletCore", .product(name: "AppletBridge", package: "Protocol"),
                .product(name: "NoodleSettingsUI", package: "SettingsUI"),
                .product(name: "NoodleLaunchChecks", package: "LaunchChecks"),
                .product(name: "NoodleWallpaper", package: "Wallpaper"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [.copy("Resources")], swiftSettings: appSettings),
        .executableTarget(
            name: "NoodletCLI",
            dependencies: ["AppletCore", .product(name: "AppletBridge", package: "Protocol")]),
        .executableTarget(name: "NoodletHost", dependencies: ["AppletCore"]),
        .executableTarget(name: "NoodletPreview", dependencies: ["AppletCore", .product(name: "AppletBridge", package: "Protocol")], swiftSettings: [.unsafeFlags(["-application-extension"])], linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]),
        .testTarget(
            name: "AppletCoreTests",
            dependencies: ["AppletCore", .product(name: "AppletBridge", package: "Protocol")]),
        .testTarget(name: "NoodleAppletTests", dependencies: ["NoodleApplet", .product(name: "NoodleLaunchChecks", package: "LaunchChecks")], swiftSettings: appSettings),
    ],
    swiftLanguageModes: [.v5]
)
