// swift-tools-version: 6.0
import PackageDescription

// The POSIX calls the Hub engine makes, on Windows: files opened, renamed and removed relative to an open folder
// without following links, owner-only access, locks, folder listings and the like, over Windows's own handles.
// Elsewhere both modules are empty, so packages can depend on this unconditionally.
let package = Package(
    name: "WindowsPOSIX",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "WindowsPOSIX", targets: ["WindowsPOSIX"])],
    targets: [
        .target(name: "CWindowsPOSIX",
                linkerSettings: [.linkedLibrary("ntdll", .when(platforms: [.windows])),
                                 .linkedLibrary("advapi32", .when(platforms: [.windows]))]),
        .target(name: "WindowsPOSIX", dependencies: ["CWindowsPOSIX"]),
        .testTarget(name: "WindowsPOSIXTests", dependencies: ["WindowsPOSIX"]),
    ],
    swiftLanguageModes: [.v5]
)
