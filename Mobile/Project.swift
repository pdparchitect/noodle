import Foundation
import ProjectDescription

// Noodle for iPhone and iPad as an Xcode project. Debug is Noodle Dev, Release is Noodle.
let version = (try? String(contentsOfFile: "VERSION", encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0.0.0"

let project = Project(
    name: "NoodleMobile",
    packages: [.local(path: "../Shared/HubLink"), .local(path: "../Shared/Wallpaper")],
    settings: .settings(
        base: [
            "DEVELOPMENT_TEAM": "S8VNVK39LH",
            "IPHONEOS_DEPLOYMENT_TARGET": "26.0",
            "SWIFT_VERSION": "6",
            "MARKETING_VERSION": .string(version),
            "CURRENT_PROJECT_VERSION": .string(version),
        ],
        configurations: [
            .debug(name: "Debug", settings: [
                "MOBILE_APP_BUNDLE_ID": "com.pdparchitect.noodle.mobile.local",
                "MOBILE_APP_NAME": "Noodle Dev",
            ]),
            .release(name: "Release", settings: [
                "MOBILE_APP_BUNDLE_ID": "com.pdparchitect.noodle.mobile",
                "MOBILE_APP_NAME": "Noodle",
            ]),
        ]
    ),
    targets: [
        .target(
            name: "NoodleMobile",
            destinations: .iOS,
            product: .app,
            productName: "NoodleMobile",
            bundleId: "com.pdparchitect.noodle.mobile",
            deploymentTargets: .iOS("26.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "$(MOBILE_APP_NAME)",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "UILaunchScreen": [:],
                // Only the system's own encryption, so TestFlight asks no export question.
                "ITSAppUsesNonExemptEncryption": false,
                // Invitation links and QR codes are noodle://join-hub links, the same as on the Mac.
                "CFBundleURLTypes": [["CFBundleURLName": "$(MOBILE_APP_BUNDLE_ID)", "CFBundleURLSchemes": ["noodle"]]],
                "NSCameraUsageDescription": "Noodle scans the QR code of a Noodle Hub invitation.",
                "NSLocalNetworkUsageDescription": "Noodle connects to your Noodle Hub on this network.",
                "NSMicrophoneUsageDescription": "Record voice messages you choose to send in your conversations. Speech is transcribed on this device.",
            ]),
            sources: ["Sources/NoodleMobile/**"],
            resources: ["Support/Assets.xcassets"],
            dependencies: [.package(product: "HubLink"), .package(product: "NoodleWallpaperCore")],
            settings: .settings(base: [
                "PRODUCT_BUNDLE_IDENTIFIER": "$(MOBILE_APP_BUNDLE_ID)",
                "CODE_SIGN_STYLE": "Automatic",
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "",
            ])
        ),
        // Runs inside the app, so it sees the bundle as the phone does.
        .target(
            name: "NoodleMobileTests",
            destinations: .iOS,
            product: .unitTests,
            bundleId: "com.pdparchitect.noodle.mobile.tests",
            deploymentTargets: .iOS("26.0"),
            infoPlist: .default,
            sources: ["Tests/NoodleMobileTests/**"],
            dependencies: [.target(name: "NoodleMobile")],
            settings: .settings(base: ["CODE_SIGN_STYLE": "Automatic"])
        ),
    ],
    schemes: [
        .scheme(
            name: "NoodleMobile",
            buildAction: .buildAction(targets: ["NoodleMobile"]),
            testAction: .targets(["NoodleMobileTests"]),
            runAction: .runAction(executable: "NoodleMobile"),
            archiveAction: .archiveAction(configuration: "Release")
        ),
    ]
)
