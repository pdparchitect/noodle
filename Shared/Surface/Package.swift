// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Surface",
    // Noodle Browser's protocol still supports macOS 15.
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "Surface", targets: ["Surface"])],
    targets: [
        .target(name: "Surface"),
        .testTarget(name: "SurfaceTests", dependencies: ["Surface"]),
    ],
    swiftLanguageModes: [.v5]
)
