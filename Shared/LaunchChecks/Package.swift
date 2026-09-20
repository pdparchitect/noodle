// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LaunchChecks",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "NoodleLaunchChecks", targets: ["NoodleLaunchChecks"])
    ],
    targets: [
        .target(name: "NoodleLaunchChecks"),
        .testTarget(name: "NoodleLaunchChecksTests", dependencies: ["NoodleLaunchChecks"])
    ]
)
