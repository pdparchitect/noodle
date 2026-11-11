// swift-tools-version: 6.0
import PackageDescription

// Noodle Server: a Hub for Linux, `noodled`, configured by a YAML file and run as a service.
// ServerCore is the server's logic, tested on macOS and Linux alike; `noodled` only puts it behind a command.
// On Linux devices reach it over msquic, through CNoodleQUIC; on a Mac it uses Noodle Hub's own listener.
let linux = TargetDependencyCondition.when(platforms: [.linux])
let mac = TargetDependencyCondition.when(platforms: [.macOS])

let package = Package(
    name: "Server",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "noodled", targets: ["noodled"])],
    dependencies: [
        // Named, so it does not matter what the checkout folder is called.
        .package(name: "Noodle", path: ".."),
        .package(path: "../Shared/HubLink"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/apple/swift-certificates", from: "1.10.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "6.0.0"),
        // Invitations' QR codes, where Core Image is not.
        .package(url: "https://github.com/fwcd/swift-qrcode-generator", from: "2.0.2"),
    ],
    targets: [
        /// msquic, loaded when first used, behind the little the link needs. Its headers are vendored
        /// in `msquic/`, under their MIT licence, since Ubuntu's package carries only the library.
        .target(name: "CNoodleQUIC", exclude: ["msquic/LICENSE"]),
        .target(name: "ServerCore", dependencies: [
            .product(name: "HubCore", package: "Noodle"),
            .product(name: "NoodleCore", package: "Noodle"),
            .product(name: "NoodleMCP", package: "Noodle"),
            .product(name: "NoodleRuntime", package: "Noodle"),
            .product(name: "HubWire", package: "HubLink"),
            // On a Mac, for development, the server listens as Noodle Hub does.
            .product(name: "HubLink", package: "HubLink", condition: mac),
            .product(name: "Yams", package: "Yams"),
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "QRCodeGenerator", package: "swift-qrcode-generator"),
            .product(name: "Crypto", package: "swift-crypto", condition: linux),
            .target(name: "CNoodleQUIC", condition: linux),
        ]),
        .executableTarget(name: "noodled", dependencies: ["ServerCore", .product(name: "HubWire", package: "HubLink")]),
        .testTarget(name: "ServerCoreTests", dependencies: [
            "ServerCore",
            .product(name: "HubCore", package: "Noodle"),
            .product(name: "NoodleCore", package: "Noodle"),
            .product(name: "HubWire", package: "HubLink"),
            .product(name: "X509", package: "swift-certificates"),
            .product(name: "HubLink", package: "HubLink", condition: mac),
            .target(name: "CNoodleQUIC", condition: linux),
        ]),
    ],
    swiftLanguageModes: [.v5]
)
