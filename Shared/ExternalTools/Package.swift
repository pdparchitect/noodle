// swift-tools-version: 6.0
import PackageDescription

/// What Noodle Browser and Noodle Computer share to serve agents outside Noodle, such as Claude Code
/// and Codex, through their command-line tools: who is calling, what each caller may use, the
/// connection and the MCP server.
let package = Package(
    name: "ExternalTools",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NoodleExternalTools", targets: ["NoodleExternalTools"]),
        .library(name: "NoodleExternalToolsUI", targets: ["NoodleExternalToolsUI"]),
    ],
    targets: [
        .target(name: "NoodleExternalTools"),
        .target(name: "NoodleExternalToolsUI", dependencies: ["NoodleExternalTools"]),
        .testTarget(name: "NoodleExternalToolsTests", dependencies: ["NoodleExternalTools"]),
        .testTarget(name: "NoodleExternalToolsUITests", dependencies: ["NoodleExternalToolsUI"]),
    ],
    swiftLanguageModes: [.v6]
)
