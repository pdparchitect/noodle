// swift-tools-version: 6.2
import PackageDescription

// What Pion adds to Noodle, with nothing that draws. The app itself is Noodle's, built by Project.swift
// from Noodle's sources with Pion's identity.
let package = Package(
    name: "Pion",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "PionCore", targets: ["PionCore"]),
        // A developer tool for trying Pion's tools against their services; the app never includes it.
        .executable(name: "pion-tool-probe", targets: ["PionToolProbe"]),
    ],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .target(name: "PionCore", dependencies: [.product(name: "NoodleCore", package: "noodle"),
                                                .product(name: "NoodleMCP", package: "noodle")]),
        .executableTarget(name: "PionToolProbe", dependencies: ["PionCore", .product(name: "NoodleToolProbe", package: "noodle")]),
        .testTarget(name: "PionCoreTests", dependencies: ["PionCore", .product(name: "NoodleCore", package: "noodle"),
                                                          .product(name: "NoodleMCP", package: "noodle")]),
    ],
    swiftLanguageModes: [.v6]
)
