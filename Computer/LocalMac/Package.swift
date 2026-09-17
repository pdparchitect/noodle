// swift-tools-version: 6.2
import PackageDescription

let package = Package(name: "LocalMac", platforms: [.macOS("26.0")], products: [
    .library(name: "LocalMacCore", targets: ["LocalMacCore"]),
    .executable(name: "LocalMacService", targets: ["LocalMacService"]),
    .executable(name: "LocalMacDesktop", targets: ["LocalMacDesktop"]),
    .executable(name: "LocalMacSetup", targets: ["LocalMacSetup"])
], dependencies: [.package(path: "../Bridge")], targets: [
    .target(name: "LocalMacPrivate", linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("CoreGraphics")]),
    .target(name: "LocalMacCore", dependencies: ["LocalMacPrivate", .product(name: "ComputerBridge", package: "Bridge")]),
    .executableTarget(name: "LocalMacService", dependencies: ["LocalMacCore"]),
    .executableTarget(name: "LocalMacDesktop", dependencies: ["LocalMacCore"]),
    .executableTarget(name: "LocalMacSetup", dependencies: ["LocalMacCore"]),
    .testTarget(name: "LocalMacCoreTests", dependencies: ["LocalMacCore"])
], swiftLanguageModes: [.v5])
