// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HubLink",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "HubLink", targets: ["HubLink"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-certificates", from: "1.10.0"),
        .package(path: "../Surface"),
    ],
    targets: [
        .target(name: "HubLink", dependencies: [.product(name: "X509", package: "swift-certificates"),
                                                .product(name: "Surface", package: "Surface")]),
        .testTarget(name: "HubLinkTests", dependencies: ["HubLink", .product(name: "X509", package: "swift-certificates")]),
    ],
    swiftLanguageModes: [.v5]
)
