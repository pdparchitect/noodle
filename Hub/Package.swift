// swift-tools-version: 6.0
import PackageDescription

// Development hooks are compiled into debug builds, and into any build made with NOODLE_DEV_HOOKS=1.
var appSettings: [SwiftSetting] = [.define("NOODLE_DEV_HOOKS", .when(configuration: .debug))]
if Context.environment["NOODLE_DEV_HOOKS"] == "1" { appSettings.append(.define("NOODLE_DEV_HOOKS")) }

let package = Package(
    name: "NoodleHub",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "NoodleHub", targets: ["NoodleHub"]),
    ],
    dependencies: [
        // Noodle itself: the Hub runs bots with the same runtime.
        .package(path: ".."),
    ],
    targets: [
        .target(
            name: "HubCore",
            dependencies: [
                .product(name: "NoodleCore", package: "noodle"),
                .product(name: "NoodleRuntime", package: "noodle"),
            ]),
        .executableTarget(name: "NoodleHub", dependencies: ["HubCore"], swiftSettings: appSettings),
        .testTarget(name: "HubCoreTests", dependencies: ["HubCore"]),
    ],
    swiftLanguageModes: [.v5]
)
