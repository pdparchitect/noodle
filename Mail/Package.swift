// swift-tools-version: 6.2
import PackageDescription

let package = Package(name: "NoodleMail", platforms: [.macOS("26.0")],
    products: [.library(name: "MailEngine", targets: ["MailEngine"]),
        .library(name: "MailCore", targets: ["MailCore"]),
        .executable(name: "NoodleMail", targets: ["NoodleMail"]),
        .executable(name: "mail-probe", targets: ["mail-probe"])],
    dependencies: [.package(url: "https://github.com/Cocoanetics/SwiftMail", exact: "1.13.0"),
        .package(path: "MailProtocol"), .package(path: "../Shared/LaunchChecks"), .package(path: "../Shared/SettingsUI")],
    targets: [
        .target(name: "MailEngine", dependencies: [.product(name: "SwiftMail", package: "SwiftMail")]),
        .target(name: "MailCore", dependencies: ["MailEngine", .product(name: "MailBridge", package: "MailProtocol")]),
        .executableTarget(name: "NoodleMail", dependencies: ["MailCore", "MailEngine", .product(name: "MailBridge", package: "MailProtocol"),
            .product(name: "NoodleLaunchChecks", package: "LaunchChecks"), .product(name: "NoodleSettingsUI", package: "SettingsUI")]),
        .executableTarget(name: "mail-probe", dependencies: ["MailEngine"]),
        .testTarget(name: "MailEngineTests", dependencies: ["MailEngine", "mail-probe", .product(name: "SwiftMail", package: "SwiftMail")],
            resources: [.copy("Fixtures")]),
        .testTarget(name: "MailCoreTests", dependencies: ["MailCore", "MailEngine", .product(name: "MailBridge", package: "MailProtocol")]),
        .testTarget(name: "NoodleMailTests", dependencies: ["NoodleMail", "MailCore", "MailEngine", .product(name: "MailBridge", package: "MailProtocol")])
    ], swiftLanguageModes: [.v5])
