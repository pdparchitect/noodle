// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NoodleApplet",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "NoodleApplet", targets: ["NoodleApplet"]),
        .executable(name: "noodlet", targets: ["NoodletCLI"]),
        .executable(name: "NoodletPreview", targets: ["NoodletPreview"]),
    ],
    dependencies: [
        .package(path: "Protocol"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
    ],
    targets: [
        .target(
            name: "AppletCore", dependencies: [.product(name: "AppletBridge", package: "Protocol")]),
        .executableTarget(
            name: "NoodleApplet",
            dependencies: [
                "AppletCore", .product(name: "AppletBridge", package: "Protocol"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            resources: [.copy("Resources")]),
        .executableTarget(
            name: "NoodletCLI",
            dependencies: ["AppletCore", .product(name: "AppletBridge", package: "Protocol")]),
        .executableTarget(name: "NoodletPreview", dependencies: ["AppletCore", .product(name: "AppletBridge", package: "Protocol")], swiftSettings: [.unsafeFlags(["-application-extension"])], linkerSettings: [.unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"])]),
        .testTarget(
            name: "AppletCoreTests",
            dependencies: ["AppletCore", .product(name: "AppletBridge", package: "Protocol")]),
        .testTarget(name: "NoodleAppletTests", dependencies: ["NoodleApplet"]),
    ],
    swiftLanguageModes: [.v5]
)
