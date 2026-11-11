// swift-tools-version: 6.0
import PackageDescription

let package = Package(name: "BrowserProtocol", platforms: [.macOS(.v15)],
    products: [.library(name: "BrowserBridge", targets: ["BrowserBridge"])],
    dependencies: [.package(path: "../../Shared/Surface")],
    targets: [.target(name: "BrowserBridge", dependencies: [.product(name: "SurfaceWire", package: "Surface"),
        .product(name: "Surface", package: "Surface", condition: .when(platforms: [.macOS, .iOS]))])], swiftLanguageModes: [.v5])
