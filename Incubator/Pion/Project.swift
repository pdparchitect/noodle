import Foundation
import ProjectDescription

// Pion as an Xcode project. Pion is its own app on Noodle's core and runtime; besides the shared
// packages it compiles a few self-contained files straight from Noodle's app, the composer, dictation and
// the transcript's scrolling, as Noodle Hub compiles the Agent Host. Debug is Pion Dev, Release is Pion.
let version = (try? String(contentsOfFile: "VERSION", encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0.0.0"

/// Every signed target uses the same identity, hardened, as the Agent Host requires.
let signing: SettingsDictionary = [
    "CODE_SIGN_STYLE": "Automatic",
    "CODE_SIGN_IDENTITY": "Apple Development",
    "ENABLE_HARDENED_RUNTIME": "YES",
]

/// As Noodle's: helpers and the Apple harness's resource bundles go into Contents/Helpers, signed there.
let embedHelpers: TargetScript = .post(script: """
    set -euo pipefail
    helpers="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
    rm -rf "$helpers"
    mkdir -p "$helpers"
    sign() { codesign --force --options runtime --timestamp=none --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$@"; }
    install_name_tool -delete_rpath "$BUILT_PRODUCTS_DIR/PackageFrameworks" "$TARGET_BUILD_DIR/$EXECUTABLE_PATH" 2>/dev/null || true
    for tool in messenger NoodleAppleAgent; do
        ditto "$BUILT_PRODUCTS_DIR/$tool" "$helpers/$tool"
    done
    sign "$helpers/messenger"
    sign --identifier "$PRODUCT_BUNDLE_IDENTIFIER.apple-agent" "$helpers/NoodleAppleAgent"
    for bundle in mlx-swift_Cmlx swift-transformers_Hub swift-crypto_Crypto; do
        if [ -d "$BUILT_PRODUCTS_DIR/$bundle.bundle" ]; then
            ditto "$BUILT_PRODUCTS_DIR/$bundle.bundle" "$helpers/$bundle.bundle"
            codesign --force --timestamp=none --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$helpers/$bundle.bundle"
        fi
    done
    """, name: "Embed Helpers", basedOnDependencyAnalysis: false)

/// A command-line helper the app runs from Contents/Helpers. The app signs it when it embeds it.
func helper(_ name: String, sources: SourceFilesList, dependencies: [TargetDependency],
            settings: SettingsDictionary = [:]) -> Target {
    .target(
        name: name,
        destinations: .macOS,
        product: .commandLineTool,
        bundleId: name,
        deploymentTargets: .macOS("26.0"),
        sources: sources,
        dependencies: dependencies,
        settings: .settings(base: ["PRODUCT_BUNDLE_IDENTIFIER": .string(name), "CODE_SIGNING_ALLOWED": "NO"]
            .merging(settings) { $1 })
    )
}

let project = Project(
    name: "Pion",
    packages: [
        .local(path: "."),
        .local(path: "../.."),
        .local(path: "../../Shared/SettingsUI"),
        .local(path: "../../Shared/HubLink"),
        .local(path: "../../Shared/Wallpaper"),
    ],
    settings: .settings(
        base: [
            "DEVELOPMENT_TEAM": "S8VNVK39LH",
            "MACOSX_DEPLOYMENT_TARGET": "26.0",
            "ARCHS": "arm64",
            // Noodle's sources are Swift 5.
            "SWIFT_VERSION": "5",
            "MARKETING_VERSION": .string(version),
            "CURRENT_PROJECT_VERSION": .string(version),
            "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO",
        ],
        configurations: [
            .debug(name: "Debug", settings: [
                "PION_APP_BUNDLE_ID": "com.pdparchitect.pion.local",
                "PION_APP_NAME": "Pion Dev",
                "PION_URL_SCHEME": "pion-dev",
            ]),
            .release(name: "Release", settings: [
                "PION_APP_BUNDLE_ID": "com.pdparchitect.pion",
                "PION_APP_NAME": "Pion",
                "PION_URL_SCHEME": "pion",
            ]),
        ]
    ),
    targets: [
        .target(
            name: "Pion",
            destinations: .macOS,
            product: .app,
            productName: "Pion",
            bundleId: "com.pdparchitect.pion",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .file(path: "Support/Info.plist"),
            sources: [
                "Sources/PionApp/**",
                // Noodle's composer, @mention completion and dictation, and the transcript's scrolling.
                // They depend on nothing else in Noodle's app; Pion's build fails if one ever does.
                "../../Sources/Noodle/ScrollableChatComposer.swift",
                "../../Sources/Noodle/ComposerFocusSurface.swift",
                "../../Sources/Noodle/ComposerAttachmentMenu.swift",
                "../../Sources/Noodle/ComposerNameCompletion.swift",
                "../../Sources/Noodle/KeyboardBindings.swift",
                "../../Sources/Noodle/VoiceRecorder.swift",
                "../../Sources/Noodle/VoiceCaptureRecovery.swift",
                "../../Sources/Noodle/VoiceInputDevice.swift",
                "../../Sources/Noodle/TranscriptScrollView.swift",
            ],
            resources: [
                "Support/Assets.xcassets",
                // Harness marks the shared settings draw, from Noodle's catalog.
                "../../Support/Assets.xcassets",
                .folderReference(path: "../../Support/ToolIcons"),
                "Support/AppSymbol.svg",
            ],
            entitlements: .file(path: "Support/Pion.entitlements"),
            scripts: [embedHelpers],
            dependencies: [
                .package(product: "PionCore"),
                .package(product: "NoodleCore"),
                .package(product: "NoodleRuntime"),
                .package(product: "NoodleRuntimeSettings"),
                .package(product: "NoodleAudioCapture"),
                .package(product: "NoodleSettingsUI"),
                .package(product: "HubLink"),
                .package(product: "NoodleWallpaper"),
                .target(name: "NoodleAgentHost"),
                .target(name: "messenger"),
                .target(name: "NoodleAppleAgent"),
            ],
            settings: .settings(
                base: signing.merging([
                    "PRODUCT_BUNDLE_IDENTIFIER": "$(PION_APP_BUNDLE_ID)",
                    "PRODUCT_NAME": "$(PION_APP_NAME)",
                    "EXECUTABLE_NAME": "Pion",
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "PionIcon",
                    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
                    "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
                    "INFOPLIST_PREPROCESS": "YES",
                    "INFOPLIST_OTHER_PREPROCESSOR_FLAGS": "-traditional",
                ]) { $1 },
                configurations: [
                    .debug(name: "Debug", settings: [
                        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) DEBUG PION_DEV_HOOKS",
                        "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "YES",
                        "ENABLE_DEBUG_DYLIB": "NO",
                    ]),
                    .release(name: "Release"),
                ]
            )
        ),
        // Launches harnesses under their sandbox. It accepts Pion alone, and Pion accepts it alone.
        .target(
            name: "NoodleAgentHost",
            destinations: .macOS,
            product: .xpc,
            bundleId: "com.pdparchitect.pion.agent-host",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleName": "Pion Agent Host",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "XPCService": ["ServiceType": "Application", "JoinExistingSession": true],
                "NoodleSigningTeam": "$(DEVELOPMENT_TEAM)",
                "NoodleApplicationIdentifier": "$(PION_APP_BUNDLE_ID)",
                "NoodleAgentHostService": "$(PION_APP_BUNDLE_ID).agent-host",
            ]),
            sources: ["../../Sources/NoodleAgentHost/**"],
            dependencies: [.package(product: "NoodleCore"), .package(product: "NoodleAgentBridge")],
            settings: .settings(base: signing.merging([
                "PRODUCT_BUNDLE_IDENTIFIER": "$(PION_APP_BUNDLE_ID).agent-host",
                "PRODUCT_NAME": "NoodleAgentHost",
            ]) { $1 })
        ),
        helper("messenger", sources: ["../../Sources/NoodleMessenger/**"],
               dependencies: [.package(product: "NoodleCore"), .package(product: "NoodleToolScripting")]),
        helper("NoodleAppleAgent", sources: ["../../Sources/NoodleAppleAgent/**"],
               dependencies: [.package(product: "NoodleCore"), .package(product: "NoodleAppleRuntime")],
               settings: [
                   "OTHER_LDFLAGS": "$(inherited) -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker $(SRCROOT)/../../Support/AppleAgent-Info.plist",
               ]),
    ]
)
