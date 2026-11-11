// swift-tools-version: 6.0
import PackageDescription

// Noodle Server: a Hub for Linux, `noodled`, configured by a YAML file and run as a service.
// ServerCore is the server's logic, tested on macOS and Linux alike; `noodled` only puts it behind a command.
let package = Package(
    name: "Server",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "noodled", targets: ["noodled"])],
    dependencies: [
        // Named, so it does not matter what the checkout folder is called.
        .package(name: "Noodle", path: ".."),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
    ],
    targets: [
        .target(name: "ServerCore", dependencies: [
            .product(name: "HubCore", package: "Noodle"),
            .product(name: "NoodleCore", package: "Noodle"),
            .product(name: "Yams", package: "Yams"),
        ]),
        .executableTarget(name: "noodled", dependencies: ["ServerCore"]),
        .testTarget(name: "ServerCoreTests", dependencies: [
            "ServerCore",
            .product(name: "HubCore", package: "Noodle"),
            .product(name: "NoodleCore", package: "Noodle"),
        ]),
    ],
    swiftLanguageModes: [.v5]
)
