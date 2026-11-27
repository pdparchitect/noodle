// swift-tools-version: 6.0
import PackageDescription

// Noodle for Windows: a WinUI 3 app over the same store as the Mac app, through NoodleCore.
// The WinRT projections under Bindings/Generated come from generate-bindings.ps1; run it before building.
let bindings = "Bindings/Generated"
// The generated projections are written for the Swift 5 language mode.
let generated: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "Windows",
    products: [.executable(name: "NoodleWindows", targets: ["NoodleWindows"])],
    dependencies: [
        // Named, so it does not matter what the checkout folder is called.
        .package(name: "Noodle", path: ".."),
        .package(path: "../Shared/HubLink"),
    ],
    targets: [
        .target(name: "CWinRT", path: "\(bindings)/CWinRT"),
        .target(name: "WindowsFoundation", dependencies: ["CWinRT"], path: "\(bindings)/WindowsFoundation",
                swiftSettings: generated),
        .target(name: "UWP", dependencies: ["CWinRT", "WindowsFoundation"], path: "\(bindings)/UWP", swiftSettings: generated),
        .target(name: "WinAppSDK", dependencies: ["CWinRT", "WindowsFoundation", "UWP"], path: "\(bindings)/WinAppSDK",
                swiftSettings: generated),
        .target(name: "WinUI", dependencies: ["CWinRT", "WindowsFoundation", "UWP", "WinAppSDK"], path: "\(bindings)/WinUI",
                swiftSettings: generated),
        .executableTarget(
            name: "NoodleWindows",
            dependencies: [
                "WinUI", "WinAppSDK", "UWP", "WindowsFoundation",
                .product(name: "NoodleCore", package: "Noodle"),
                .product(name: "NoodleRuntime", package: "Noodle"),
                .product(name: "HubLink", package: "HubLink"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // A window app, without a console, in release builds; debug builds keep the console for print.
            linkerSettings: [.unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"],
                                          .when(configuration: .release))]
        ),
    ]
)
