// swift-tools-version: 6.0
import PackageDescription

let package = Package(name: "BrowserProtocol", platforms: [.macOS(.v15)],
    products: [.library(name: "BrowserBridge", targets: ["BrowserBridge"])],
    dependencies: [.package(path: "../../Shared/Surface")],
    targets: [.target(name: "BrowserBridge", dependencies: [.product(name: "Surface", package: "Surface")])], swiftLanguageModes: [.v5])
