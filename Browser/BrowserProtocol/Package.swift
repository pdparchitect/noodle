// swift-tools-version: 6.0
import PackageDescription

let package = Package(name: "BrowserProtocol", platforms: [.macOS(.v15)],
    products: [.library(name: "BrowserBridge", targets: ["BrowserBridge"])],
    dependencies: [.package(path: "../../Shared/Surface")],
    targets: [.target(name: "BrowserBridge", dependencies: [.product(name: "SurfaceWire", package: "Surface"),
        .product(name: "Surface", package: "Surface", condition: .when(platforms: [.macOS, .iOS]))])], swiftLanguageModes: [.v5])

#if os(Windows)
// Payload files pass between Noodle and Noodle Browser on a Mac only, and need POSIX file calls.
package.targets.first { $0.name == "BrowserBridge" }?.exclude = ["TransferFiles.swift"]
#endif
