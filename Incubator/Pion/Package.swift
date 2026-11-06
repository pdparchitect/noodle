// swift-tools-version: 6.2
import PackageDescription

let package = Package(name: "Pion", platforms: [.macOS("26.0")],
    products: [.executable(name: "Pion", targets: ["Pion"])],
    targets: [.executableTarget(name: "Pion")],
    swiftLanguageModes: [.v6])
