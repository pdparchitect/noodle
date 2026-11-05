// swift-tools-version: 6.0
import PackageDescription

// Which product an app is, for the code apps share: its name and the identifier its own ones derive from.
let package = Package(
    name: "Product",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "ProductIdentity", targets: ["ProductIdentity"])],
    targets: [
        .target(name: "ProductIdentity"),
        .testTarget(name: "ProductIdentityTests", dependencies: ["ProductIdentity"]),
    ]
)
