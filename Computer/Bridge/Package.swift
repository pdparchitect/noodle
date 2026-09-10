// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "ComputerBridge", platforms: [.macOS(.v15)],
    products: [.library(name: "ComputerBridge", targets: ["ComputerBridge"])],
    targets: [.target(name: "ComputerBridge"),
              .executableTarget(name: "ComputerBridgeProbe", dependencies: ["ComputerBridge"]),
              .testTarget(name: "ComputerBridgeTests", dependencies: ["ComputerBridge"])],
    swiftLanguageModes: [.v5])
