// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HubLink",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "HubLink", targets: ["HubLink"]),
               // The messages alone, which need no Apple framework beyond CryptoKit.
               .library(name: "HubWire", targets: ["HubWire"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-certificates", from: "1.10.0"),
        .package(path: "../Surface"),
        // The wire types Noodle Push takes, which need nothing but swift-crypto.
        .package(path: "../../Push/Wire"),
    ],
    targets: [
        .target(name: "HubWire", dependencies: [.product(name: "PushWire", package: "Wire"),
                                                .product(name: "SurfaceWire", package: "Surface")]),
        .target(name: "HubLink", dependencies: ["HubWire", .product(name: "X509", package: "swift-certificates"),
                                                .product(name: "Surface", package: "Surface"),
                                                .product(name: "PushWire", package: "Wire")]),
        .testTarget(name: "HubLinkTests", dependencies: ["HubLink", "HubWire", .product(name: "X509", package: "swift-certificates")],
                    exclude: ["Fixtures"]),
    ],
    swiftLanguageModes: [.v5]
)
