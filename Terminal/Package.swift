// swift-tools-version: 6.2
import PackageDescription

// Development hooks are compiled into debug builds and into builds that ask for them; never into a release.
let hooks: [SwiftSetting] = [.define("NOODLE_DEV_HOOKS", .when(configuration: .debug))]
    + (Context.environment["NOODLE_DEV_HOOKS"] == "1" ? [.define("NOODLE_DEV_HOOKS")] : [])

let package = Package(name: "NoodleTerminal", platforms: [.macOS("26.0")],
    products: [.executable(name: "noodle", targets: ["NoodleTerminal"])],
    dependencies: [.package(path: "../Shared/HubLink"),
        // Pre-1.0, so minor releases may break the API: taken one at a time.
        .package(url: "https://github.com/SwiftTUI/swift-tui", .upToNextMinor(from: "0.20.1"))],
    targets: [
        .target(name: "TerminalCore", dependencies: [.product(name: "HubLink", package: "HubLink")]),
        .executableTarget(name: "NoodleTerminal", dependencies: ["TerminalCore", .product(name: "HubLink", package: "HubLink"),
            // The terminal-only launcher: SwiftTUI's own product also links its web host, which serves the app on a port.
            .product(name: "SwiftTUICLI", package: "swift-tui"), .product(name: "SwiftTUIArguments", package: "swift-tui")],
            swiftSettings: hooks),
        .testTarget(name: "TerminalCoreTests", dependencies: ["TerminalCore", .product(name: "HubLink", package: "HubLink")])
    ], swiftLanguageModes: [.v6])
