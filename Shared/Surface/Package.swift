// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Surface",
    // Noodle Browser's protocol still supports macOS 15.
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "Surface", targets: ["Surface"]),
               // What crosses a link about a live view, with no UI framework.
               .library(name: "SurfaceWire", targets: ["SurfaceWire"])],
    targets: [
        .target(name: "SurfaceWire"),
        .target(name: "Surface", dependencies: ["SurfaceWire"]),
        .testTarget(name: "SurfaceTests", dependencies: ["Surface"]),
        .testTarget(name: "SurfaceWireTests", dependencies: ["SurfaceWire"]),
    ],
    swiftLanguageModes: [.v5]
)

#if os(Linux)
// Only what crosses the wire builds on Linux; live views need Apple's video and UI frameworks.
package.targets.removeAll { !["SurfaceWire", "SurfaceWireTests"].contains($0.name) }
// The protocol packages name Surface for Apple platforms only, but the product must still exist.
package.products = [.library(name: "Surface", targets: ["SurfaceWire"]), .library(name: "SurfaceWire", targets: ["SurfaceWire"])]
#endif
