// swift-tools-version: 6.0
import PackageDescription

let package = Package(name: "ComputerPresentation", platforms: [.macOS(.v15)],
    products: [.library(name: "ComputerDocument", targets: ["ComputerDocument"])],
    dependencies: [.package(path: "../Bridge")],
    targets: [
        .target(name: "ComputerDocument", dependencies: [.product(name: "ComputerBridge", package: "Bridge")]),
        .testTarget(name: "ComputerDocumentTests", dependencies: ["ComputerDocument"])
    ], swiftLanguageModes: [.v5])
