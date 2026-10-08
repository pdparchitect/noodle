// swift-tools-version: 6.2
import PackageDescription

// Development hooks are compiled into debug builds and into builds that ask for them; never into a release.
let hooks: [SwiftSetting] = [.define("NOODLE_DEV_HOOKS", .when(configuration: .debug))]
    + (Context.environment["NOODLE_DEV_HOOKS"] == "1" ? [.define("NOODLE_DEV_HOOKS")] : [])

let package = Package(name: "NoodleBrowser", platforms: [.macOS("26.0")],
    products: [.executable(name: "NoodleBrowser", targets: ["NoodleBrowser"]),
        .executable(name: "noodle-browser", targets: ["NoodleBrowserCLI"]),
        .library(name: "BrowserCore", targets: ["BrowserCore"]),
        .library(name: "BrowserExternal", targets: ["BrowserExternal"])],
    dependencies: [.package(path: "BrowserProtocol"), .package(path: "../Shared/SettingsUI"),
        .package(path: "../Shared/Wallpaper"), .package(path: "../Shared/LaunchChecks"), .package(path: "../Shared/ExternalTools"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")],
    targets: [
        .target(name: "BrowserCore", dependencies: [.product(name: "BrowserBridge", package: "BrowserProtocol"),
            .product(name: "NoodleWallpaperCore", package: "Wallpaper")]),
        // What the app and its command-line tool share to serve apps outside Noodle.
        .target(name: "BrowserExternal", dependencies: [.product(name: "BrowserBridge", package: "BrowserProtocol"),
            .product(name: "NoodleExternalTools", package: "ExternalTools")]),
        .executableTarget(name: "NoodleBrowserCLI", dependencies: ["BrowserExternal"]),
        .executableTarget(name: "NoodleBrowser", dependencies: ["BrowserCore", "BrowserExternal", .product(name: "BrowserBridge", package: "BrowserProtocol"),
            .product(name: "NoodleExternalToolsUI", package: "ExternalTools"),
            .product(name: "NoodleSettingsUI", package: "SettingsUI"), .product(name: "NoodleWallpaper", package: "Wallpaper"),
            .product(name: "NoodleLaunchChecks", package: "LaunchChecks"),
            .product(name: "Sparkle", package: "Sparkle")], resources: [.copy("Resources")], swiftSettings: hooks),
        .testTarget(name: "BrowserCoreTests", dependencies: ["BrowserCore"]),
        .testTarget(name: "BrowserExternalTests", dependencies: ["BrowserExternal"]),
        .testTarget(name: "NoodleBrowserTests", dependencies: ["NoodleBrowser", "BrowserExternal", .product(name: "NoodleLaunchChecks", package: "LaunchChecks")])
    ], swiftLanguageModes: [.v5])
