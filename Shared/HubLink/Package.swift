// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HubLink",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "HubLink", targets: ["HubLink"]),
               // The messages alone, which need no Apple framework.
               .library(name: "HubWire", targets: ["HubWire"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-certificates", from: "1.10.0"),
        .package(path: "../Surface"),
        // The wire types Noodle Push takes, which need nothing but swift-crypto.
        .package(path: "../../Push/Wire"),
        // CryptoKit's API where there is no CryptoKit; Push/Wire already takes it.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "6.0.0"),
    ],
    targets: [
        .target(name: "HubWire", dependencies: [.product(name: "PushWire", package: "Wire"),
                                                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
                                                .product(name: "SurfaceWire", package: "Surface")]),
        /// msquic, loaded when first used, behind the little the link needs: Linux's QUIC, where Apple
        /// platforms use Network.framework. Its headers are vendored in `msquic/`, under their MIT
        /// licence, since Ubuntu's package carries only the library.
        .target(name: "CNoodleQUIC", exclude: ["msquic/LICENSE"]),
        .target(name: "HubLink", dependencies: ["HubWire", .product(name: "X509", package: "swift-certificates"),
                                                .product(name: "Surface", package: "Surface"),
                                                .product(name: "PushWire", package: "Wire"),
                                                .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux])),
                                                .target(name: "CNoodleQUIC", condition: .when(platforms: [.linux]))]),
        .testTarget(name: "HubLinkTests", dependencies: ["HubLink", "HubWire", .product(name: "X509", package: "swift-certificates")]),
        // The link on Linux, over msquic, and what both platforms share of it.
        .testTarget(name: "HubLinkQUICTests", dependencies: ["HubLink", "HubWire", .product(name: "X509", package: "swift-certificates"),
                                                             .target(name: "CNoodleQUIC", condition: .when(platforms: [.linux]))]),
        // The wire alone, which also runs where HubLink cannot.
        .testTarget(name: "HubWireTests", dependencies: ["HubWire", .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))],
                    exclude: ["Fixtures"]),
    ],
    swiftLanguageModes: [.v5]
)

#if os(Linux)
// HubLinkTests exercise the Apple transport, which Linux does not have.
package.targets.removeAll { $0.name == "HubLinkTests" }
#endif
