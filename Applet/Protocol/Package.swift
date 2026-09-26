// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppletProtocol", platforms: [.macOS(.v15)],
    products: [.library(name: "AppletBridge", targets: ["AppletBridge"])],
    dependencies: [.package(path: "../../Shared/Surface")],
    targets: [.target(name: "AppletBridge", dependencies: [.product(name: "Surface", package: "Surface")])], swiftLanguageModes: [.v5])
