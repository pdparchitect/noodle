// swift-tools-version: 6.0
import PackageDescription

// Reading patches for review, the same on the Mac and on the phone.
let package = Package(
    name: "Patch",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "NoodlePatch", targets: ["NoodlePatch"])
    ],
    targets: [
        .target(name: "NoodlePatch"),
        .testTarget(name: "NoodlePatchTests", dependencies: ["NoodlePatch"])
    ]
)
