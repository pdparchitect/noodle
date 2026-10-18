import Foundation
import ProjectDescription

// Noodle for iPhone and iPad as an Xcode project. Debug is Noodle Dev, Release is Noodle.
let version = (try? String(contentsOfFile: "VERSION", encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0.0.0"

let project = Project(
    name: "NoodleMobile",
    packages: [.local(path: "../Shared/HubLink"), .local(path: "../Shared/Wallpaper"), .local(path: "../Shared/Brand"),
               .local(path: "../Shared/Patch"), .local(path: "../Applet/Protocol")],
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
                "MOBILE_CLOUDKIT_ENVIRONMENT": "Development",
            ]),
            .release(name: "Release", settings: [
                "MOBILE_APP_BUNDLE_ID": "com.pdparchitect.noodle.mobile",
                "MOBILE_APP_NAME": "Noodle",
                "MOBILE_CLOUDKIT_ENVIRONMENT": "Production",
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
                "NSCameraUsageDescription": "Noodle takes photos you send or use as your picture, scans the QR code of a Noodle Hub invitation, and noodlets you open use the camera when they ask.",
                // Without it the share sheet leaves out Save Image.
                "NSPhotoLibraryAddUsageDescription": "Noodle saves pictures and videos from conversations to your photos when you choose Save.",
                "NSLocalNetworkUsageDescription": "Noodle connects to your Noodle Hub on this network.",
                "NSMicrophoneUsageDescription": "Record voice messages you choose to send, transcribed on this device, talk with bots on calls you start, and let noodlets you open listen when they ask.",
                // A call keeps going with the screen locked or another app in front; CallKit refuses calls without voip.
                "UIBackgroundModes": ["audio", "voip"],
                // Shared with the notification and share extensions, which reach the Hubs kept there, and the widgets.
                "NoodleAppGroup": "group.$(MOBILE_APP_BUNDLE_ID)",
                // Conversations told to iOS, which the share sheet suggests and reply notifications show as messages.
                "NSUserActivityTypes": ["INSendMessageIntent"],
            ]),
            sources: ["Sources/NoodleMobile/**", "Sources/Shared/**"],
            // The Mac's samples of each harness voice, to hear before choosing one.
            resources: ["Support/Assets.xcassets", .folderReference(path: "../Support/VoicePreviews")],
            entitlements: .file(path: "Support/NoodleMobile.entitlements"),
            dependencies: [.package(product: "HubLink"), .package(product: "NoodleWallpaperCore"), .package(product: "NoodleBrand"),
                           .package(product: "NoodletRuntime"), .package(product: "NoodlePatch"),
                           .target(name: "NoodleMobileNotifications"), .target(name: "NoodleMobileShare"),
                           .target(name: "NoodleMobileWidgets")],
            settings: .settings(base: [
                "PRODUCT_BUNDLE_IDENTIFIER": "$(MOBILE_APP_BUNDLE_ID)",
                "CODE_SIGN_STYLE": "Automatic",
                "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "",
            ])
        ),
        // Names the bot and shows its reply in a notification of unread replies, asking the Hub.
        .target(
            name: "NoodleMobileNotifications",
            destinations: .iOS,
            product: .appExtension,
            productName: "NoodleMobileNotifications",
            bundleId: "com.pdparchitect.noodle.mobile.notifications",
            deploymentTargets: .iOS("26.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "$(MOBILE_APP_NAME)",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "NoodleAppGroup": "group.$(MOBILE_APP_BUNDLE_ID)",
                "NSExtension": [
                    "NSExtensionPointIdentifier": "com.apple.usernotifications.service",
                    "NSExtensionPrincipalClass": "$(PRODUCT_MODULE_NAME).NotificationService",
                ],
            ]),
            sources: ["Sources/NoodleMobileNotifications/**", "Sources/Shared/**"],
            entitlements: .file(path: "Support/NoodleMobileNotifications.entitlements"),
            dependencies: [.package(product: "HubLink")],
            settings: .settings(base: [
                "PRODUCT_BUNDLE_IDENTIFIER": "$(MOBILE_APP_BUNDLE_ID).notifications",
                "CODE_SIGN_STYLE": "Automatic",
            ])
        ),
        // Noodle in the share sheet: sends what another app shares to a bot or group, straight to its Hub.
        .target(
            name: "NoodleMobileShare",
            destinations: .iOS,
            product: .appExtension,
            productName: "NoodleMobileShare",
            bundleId: "com.pdparchitect.noodle.mobile.share",
            deploymentTargets: .iOS("26.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "$(MOBILE_APP_NAME)",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "NoodleAppGroup": "group.$(MOBILE_APP_BUNDLE_ID)",
                "NSExtension": [
                    "NSExtensionPointIdentifier": "com.apple.share-services",
                    "NSExtensionPrincipalClass": "$(PRODUCT_MODULE_NAME).ShareViewController",
                    "NSExtensionAttributes": [
                        "NSExtensionActivationRule": [
                            "NSExtensionActivationSupportsImageWithMaxCount": 10,
                            "NSExtensionActivationSupportsMovieWithMaxCount": 10,
                            "NSExtensionActivationSupportsFileWithMaxCount": 10,
                            "NSExtensionActivationSupportsWebURLWithMaxCount": 1,
                            "NSExtensionActivationSupportsText": true,
                        ],
                        // The conversations iOS suggests at the top of the share sheet open here.
                        "IntentsSupported": ["INSendMessageIntent"],
                    ],
                ],
            ]),
            sources: ["Sources/NoodleMobileShare/**", "Sources/Shared/**"],
            entitlements: .file(path: "Support/NoodleMobileShare.entitlements"),
            dependencies: [.package(product: "HubLink")],
            settings: .settings(base: [
                "PRODUCT_BUNDLE_IDENTIFIER": "$(MOBILE_APP_BUNDLE_ID).share",
                "CODE_SIGN_STYLE": "Automatic",
            ])
        ),
        // Bots on the Home Screen and Lock Screen, as the app last left them in its group; a tap opens the bot's chat.
        // It reads only that shelf, so it needs neither the Hubs nor HubLink.
        .target(
            name: "NoodleMobileWidgets",
            destinations: .iOS,
            product: .appExtension,
            productName: "NoodleMobileWidgets",
            bundleId: "com.pdparchitect.noodle.mobile.widgets",
            deploymentTargets: .iOS("26.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "$(MOBILE_APP_NAME)",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "NoodleAppGroup": "group.$(MOBILE_APP_BUNDLE_ID)",
                "NSExtension": ["NSExtensionPointIdentifier": "com.apple.widgetkit-extension"],
            ]),
            sources: ["Sources/NoodleMobileWidgets/**", "Sources/Shared/BotWidgets.swift"],
            entitlements: .file(path: "Support/NoodleMobileWidgets.entitlements"),
            dependencies: [.sdk(name: "WidgetKit", type: .framework), .sdk(name: "AppIntents", type: .framework)],
            settings: .settings(base: [
                "PRODUCT_BUNDLE_IDENTIFIER": "$(MOBILE_APP_BUNDLE_ID).widgets",
                "CODE_SIGN_STYLE": "Automatic",
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
