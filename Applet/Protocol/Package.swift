// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppletProtocol", platforms: [.macOS(.v15)],
    products: [.library(name: "AppletBridge", targets: ["AppletBridge"])],
    targets: [.target(name: "AppletBridge")], swiftLanguageModes: [.v5])
