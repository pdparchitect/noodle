// swift-tools-version: 6.2
import PackageDescription
// The provider and Noodle share the versioned Computer/Bridge protocol.

let package = Package(
    name: "NoodleComputer",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "NoodleComputer", targets: ["NoodleComputer"])],
    dependencies: [
        .package(path: "../Shared/Wallpaper"),
        .package(path: "Bridge"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4"),
        .package(url: "https://github.com/apple/containerization.git", exact: "0.43.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")
    ],
    targets: [
        .target(name: "ComputerCore", dependencies: [.product(name: "NoodleWallpaperCore", package: "Wallpaper")], resources: [.process("Resources")]),
        .executableTarget(name: "NoodleComputer", dependencies: [
            "ComputerCore",
            .product(name: "NoodleWallpaper", package: "Wallpaper"),
            .product(name: "Sparkle", package: "Sparkle"),
            .product(name: "ComputerBridge", package: "Bridge"),
            .product(name: "SwiftTerm", package: "SwiftTerm"),
            .product(name: "Containerization", package: "containerization"),
            .product(name: "ContainerizationEXT4", package: "containerization"),
            .product(name: "ContainerizationExtras", package: "containerization"),
            .product(name: "ContainerizationOCI", package: "containerization")
        ]),
        .testTarget(name: "ComputerCoreTests", dependencies: ["ComputerCore"]),
        .testTarget(name: "ComputerStorageTests", dependencies: ["NoodleComputer"])
    ],
    swiftLanguageModes: [.v5]
)
