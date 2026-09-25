// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HubLink",
    platforms: [.macOS("26.0")],
    products: [.library(name: "HubLink", targets: ["HubLink"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-certificates", from: "1.10.0"),
    ],
    targets: [
        .target(name: "HubLink", dependencies: [.product(name: "X509", package: "swift-certificates")]),
        .testTarget(name: "HubLinkTests", dependencies: ["HubLink"]),
    ],
    swiftLanguageModes: [.v5]
)
