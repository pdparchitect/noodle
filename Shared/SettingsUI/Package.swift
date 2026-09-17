// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SettingsUI",
    platforms: [.macOS(.v15)],
    products: [.library(name: "NoodleSettingsUI", targets: ["NoodleSettingsUI"])],
    targets: [
        // WindowFocusGuard.swift links to Applet's runtime resource so the apps
        // and standalone native noodlets compile the same event policy.
        .target(name: "NoodleSettingsUI"),
        .testTarget(name: "NoodleSettingsUITests", dependencies: ["NoodleSettingsUI"])
    ],
    swiftLanguageModes: [.v5]
)
