// swift-tools-version: 6.2
import PackageDescription

// What Rook adds to Noodle, with nothing that draws. The app itself is Noodle's, built by Project.swift
// from Noodle's sources with Rook's identity.
let package = Package(
    name: "Rook",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "RookCore", targets: ["RookCore"]),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .target(name: "RookCore", dependencies: [.product(name: "NoodleCore", package: "noodle"),
                                                .product(name: "NoodleToolConnections", package: "noodle")]),
        .testTarget(name: "RookCoreTests", dependencies: ["RookCore", .product(name: "NoodleCore", package: "noodle"),
                                                          .product(name: "NoodleToolConnections", package: "noodle")]),
    ],
    swiftLanguageModes: [.v6]
)
