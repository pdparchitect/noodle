import Foundation
import ProjectDescription

// Noodle Mail as an Xcode project. The code stays in Swift packages; this describes the app bundle
// they are assembled into. Debug is Noodle Mail Dev, Release is Noodle Mail.
let version = (try? String(contentsOfFile: "VERSION", encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0.0.0"

let project = Project(
    name: "NoodleMail",
    packages: [
        .local(path: "."),
        .local(path: "MailProtocol"),
        .local(path: "../Shared/LaunchChecks"),
        .local(path: "../Shared/SettingsUI"),
    ],
    settings: .settings(
        base: [
            "DEVELOPMENT_TEAM": "S8VNVK39LH",
            "MACOSX_DEPLOYMENT_TARGET": "26.0",
            // Releases ship for Apple silicon only.
            "ARCHS": "arm64",
            "SWIFT_VERSION": "5",
            "MARKETING_VERSION": .string(version),
            "CURRENT_PROJECT_VERSION": .string(version),
        ],
        configurations: [
            .debug(name: "Debug", settings: [
                "MAIL_APP_BUNDLE_ID": "com.pdparchitect.noodle.mail.local",
                "MAIL_APP_NAME": "Noodle Mail Dev",
                "MAIL_GROUP_SUFFIX": "com.pdparchitect.noodle.mails.local",
                "MAIL_URL_SCHEME": "noodlemail-dev",
            ]),
            .release(name: "Release", settings: [
                "MAIL_APP_BUNDLE_ID": "com.pdparchitect.noodle.mail",
                "MAIL_APP_NAME": "Noodle Mail",
                "MAIL_GROUP_SUFFIX": "com.pdparchitect.noodle.mails",
                "MAIL_URL_SCHEME": "noodlemail",
                // Signing adds get-task-allow for the debugger; a release carries only its own entitlements.
                "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO",
            ]),
        ]
    ),
    targets: [
        .target(
            name: "NoodleMail",
            destinations: .macOS,
            product: .app,
            productName: "NoodleMail",
            bundleId: "com.pdparchitect.noodle.mail",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .file(path: "Support/Info.plist"),
            sources: ["Sources/NoodleMail/**"],
            entitlements: .file(path: "Support/Mail.entitlements"),
            dependencies: [
                .package(product: "MailCore"),
                .package(product: "MailEngine"),
                .package(product: "MailBridge"),
                .package(product: "NoodleLaunchChecks"),
                .package(product: "NoodleSettingsUI"),
            ],
            settings: .settings(
                base: [
                    "CODE_SIGN_STYLE": "Automatic",
                    "CODE_SIGN_IDENTITY": "Apple Development",
                    "ENABLE_HARDENED_RUNTIME": "YES",
                    "PRODUCT_BUNDLE_IDENTIFIER": "$(MAIL_APP_BUNDLE_ID)",
                    "PRODUCT_NAME": "$(MAIL_APP_NAME)",
                    "EXECUTABLE_NAME": "NoodleMail",
                ],
                configurations: [
                    .debug(name: "Debug", settings: ["SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) DEBUG NOODLE_DEV_HOOKS"]),
                    .release(name: "Release"),
                ]
            )
        ),
    ]
)
