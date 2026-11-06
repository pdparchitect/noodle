// swift-tools-version: 6.2
import PackageDescription

let package = Package(name: "Rook", platforms: [.macOS("26.0")],
    products: [.executable(name: "Rook", targets: ["Rook"])],
    targets: [.executableTarget(name: "Rook")],
    swiftLanguageModes: [.v6])
