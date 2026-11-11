// swift-tools-version: 6.0
import PackageDescription

let surface = Target.Dependency.product(name: "Surface", package: "Surface")
// AppletBridge passes on live views only on Apple platforms; elsewhere only what crosses the wire.
let surfaceWire: [Target.Dependency] = [.product(name: "SurfaceWire", package: "Surface"), .product(name: "Surface", package: "Surface", condition: .when(platforms: [.macOS, .iOS]))]

let package = Package(
    name: "AppletProtocol", platforms: [.macOS(.v15), .iOS("26.0")],
    products: [
        .library(name: "AppletBridge", targets: ["AppletBridge"]),
        .library(name: "NoodletFormat", targets: ["NoodletFormat"]),
        .library(name: "NoodletRuntime", targets: ["NoodletRuntime"]),
    ],
    dependencies: [.package(path: "../../Shared/Surface")],
    targets: [
        /// What a noodlet is, readable on any device: its manifest, paths and errors.
        .target(name: "NoodletFormat", dependencies: [.product(name: "SurfaceWire", package: "Surface")]),
        /// How Noodle, Noodle Hub and the noodlet command talk to Noodle Applet on a Mac.
        .target(name: "AppletBridge", dependencies: ["NoodletFormat"] + surfaceWire),
        /// A noodlet's page in a confined web view, which each app extends for where it runs.
        .target(name: "NoodletRuntime", dependencies: ["NoodletFormat", surface], resources: [.copy("Bridge.js")]),
        .testTarget(name: "NoodletRuntimeTests", dependencies: ["NoodletRuntime"]),
    ],
    swiftLanguageModes: [.v5])
