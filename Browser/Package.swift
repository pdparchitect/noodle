// swift-tools-version: 6.2
import PackageDescription

// Development hooks are compiled into debug builds and into builds that ask for them; never into a release.
let hooks: [SwiftSetting] = [.define("NOODLE_DEV_HOOKS", .when(configuration: .debug))]
    + (Context.environment["NOODLE_DEV_HOOKS"] == "1" ? [.define("NOODLE_DEV_HOOKS")] : [])

let package = Package(name: "NoodleBrowser", platforms: [.macOS("26.0")],
    products: [.executable(name: "NoodleBrowser", targets: ["NoodleBrowser"])],
    dependencies: [.package(path: "BrowserProtocol"), .package(path: "../Shared/SettingsUI"),
        .package(path: "../Shared/Wallpaper"), .package(path: "../Shared/LaunchChecks"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")],
    targets: [
        .target(name: "BrowserCore", dependencies: [.product(name: "BrowserBridge", package: "BrowserProtocol"),
            .product(name: "NoodleWallpaperCore", package: "Wallpaper")]),
        .executableTarget(name: "NoodleBrowser", dependencies: ["BrowserCore", .product(name: "BrowserBridge", package: "BrowserProtocol"),
            .product(name: "NoodleSettingsUI", package: "SettingsUI"), .product(name: "NoodleWallpaper", package: "Wallpaper"),
            .product(name: "NoodleLaunchChecks", package: "LaunchChecks"),
            .product(name: "Sparkle", package: "Sparkle")], resources: [.copy("Resources")], swiftSettings: hooks),
        .testTarget(name: "BrowserCoreTests", dependencies: ["BrowserCore"]),
        .testTarget(name: "NoodleBrowserTests", dependencies: ["NoodleBrowser", .product(name: "NoodleLaunchChecks", package: "LaunchChecks")])
    ], swiftLanguageModes: [.v5])
