// swift-tools-version: 6.2
import PackageDescription

// Development hooks are compiled into debug builds and into builds that ask for them; never into a release.
let hooks: [SwiftSetting] = [.define("NOODLE_DEV_HOOKS", .when(configuration: .debug))]
    + (Context.environment["NOODLE_DEV_HOOKS"] == "1" ? [.define("NOODLE_DEV_HOOKS")] : [])

let package = Package(name: "NoodleTerminal", platforms: [.macOS("26.0")],
    products: [.executable(name: "noodle", targets: ["NoodleTerminal"])],
    dependencies: [.package(path: "../Shared/HubLink")],
    targets: [
        .target(name: "TerminalCore", dependencies: [.product(name: "HubLink", package: "HubLink")]),
        // What the screen is drawn from that needs no terminal: keys, widths and wrapping, markdown, lists and
        // commands, apart from the app so tests reach them on every system.
        .target(name: "TerminalScreen", dependencies: [.product(name: "HubLink", package: "HubLink")]),
        .executableTarget(name: "NoodleTerminal", dependencies: ["TerminalCore", "TerminalScreen", .product(name: "HubLink", package: "HubLink")],
            swiftSettings: hooks),
        .testTarget(name: "TerminalCoreTests", dependencies: ["TerminalCore", .product(name: "HubLink", package: "HubLink")]),
        .testTarget(name: "TerminalScreenTests", dependencies: ["TerminalScreen"])
    ], swiftLanguageModes: [.v6])
