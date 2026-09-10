// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Wallpaper",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NoodleWallpaperCore", targets: ["NoodleWallpaperCore"]),
        .library(name: "NoodleWallpaper", targets: ["NoodleWallpaper"])
    ],
    targets: [
        .target(name: "NoodleWallpaperCore"),
        .target(name: "NoodleWallpaper", dependencies: ["NoodleWallpaperCore"])
    ],
    swiftLanguageModes: [.v5]
)
