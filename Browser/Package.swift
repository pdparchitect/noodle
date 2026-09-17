// swift-tools-version: 6.2
import PackageDescription

let package = Package(name: "NoodleBrowser", platforms: [.macOS("26.0")],
    products: [.executable(name: "NoodleBrowser", targets: ["NoodleBrowser"])],
    dependencies: [.package(path: "BrowserProtocol"), .package(path: "../Shared/SettingsUI"),
        .package(path: "../Shared/Wallpaper"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")],
    targets: [
        .target(name: "BrowserCore", dependencies: [.product(name: "BrowserBridge", package: "BrowserProtocol"),
            .product(name: "NoodleWallpaperCore", package: "Wallpaper")]),
        .executableTarget(name: "NoodleBrowser", dependencies: ["BrowserCore", .product(name: "BrowserBridge", package: "BrowserProtocol"),
            .product(name: "NoodleSettingsUI", package: "SettingsUI"), .product(name: "NoodleWallpaper", package: "Wallpaper"),
            .product(name: "Sparkle", package: "Sparkle")], resources: [.copy("Resources")]),
        .testTarget(name: "BrowserCoreTests", dependencies: ["BrowserCore"]),
        .testTarget(name: "NoodleBrowserTests", dependencies: ["NoodleBrowser"])
    ], swiftLanguageModes: [.v5])
