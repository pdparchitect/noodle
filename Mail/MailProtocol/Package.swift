// swift-tools-version: 6.0
import PackageDescription

let package = Package(name: "MailProtocol", platforms: [.macOS(.v15)],
    products: [.library(name: "MailBridge", targets: ["MailBridge"])],
    targets: [.target(name: "MailBridge"),
        .testTarget(name: "MailBridgeTests", dependencies: ["MailBridge"])], swiftLanguageModes: [.v5])
