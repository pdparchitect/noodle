// swift-tools-version: 6.2
import PackageDescription

// What Pion adds to Noodle, with nothing that draws. The app itself is Noodle's, built by Project.swift
// from Noodle's sources with Pion's identity.
let package = Package(
    name: "Pion",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "PionCore", targets: ["PionCore"]),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .target(name: "PionCore", dependencies: [.product(name: "NoodleCore", package: "noodle")]),
        .testTarget(name: "PionCoreTests", dependencies: ["PionCore", .product(name: "NoodleCore", package: "noodle")]),
    ],
    swiftLanguageModes: [.v6]
)
