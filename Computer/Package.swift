// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NoodleComputer",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "NoodleComputer", targets: ["NoodleComputer"])],
    dependencies: [
        .package(url: "https://github.com/apple/containerization.git", exact: "0.43.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")
    ],
    targets: [
        .target(name: "ComputerCore"),
        .executableTarget(name: "NoodleComputer", dependencies: [
            "ComputerCore",
            .product(name: "SwiftTerm", package: "SwiftTerm"),
            .product(name: "Containerization", package: "containerization"),
            .product(name: "ContainerizationEXT4", package: "containerization"),
            .product(name: "ContainerizationExtras", package: "containerization")
        ]),
        .testTarget(name: "ComputerCoreTests", dependencies: ["ComputerCore"])
    ],
    swiftLanguageModes: [.v5]
)
