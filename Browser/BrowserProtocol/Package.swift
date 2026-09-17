// swift-tools-version: 6.0
import PackageDescription

let package = Package(name: "BrowserProtocol", platforms: [.macOS(.v15)],
    products: [.library(name: "BrowserBridge", targets: ["BrowserBridge"])],
    targets: [.target(name: "BrowserBridge")], swiftLanguageModes: [.v5])
