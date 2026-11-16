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
    sign() { codesign --force --options runtime "$PION_CODESIGN_TIMESTAMP" --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$@"; }
    install_name_tool -delete_rpath "$BUILT_PRODUCTS_DIR/PackageFrameworks" "$TARGET_BUILD_DIR/$EXECUTABLE_PATH" 2>/dev/null || true
    for tool in messenger NoodleAppleAgent; do
        ditto "$BUILT_PRODUCTS_DIR/$tool" "$helpers/$tool"
    done
    sign "$helpers/messenger"
    sign --identifier "$PRODUCT_BUNDLE_IDENTIFIER.apple-agent" "$helpers/NoodleAppleAgent"
    for bundle in mlx-swift_Cmlx swift-transformers_Hub swift-crypto_Crypto; do
        if [ -d "$BUILT_PRODUCTS_DIR/$bundle.bundle" ]; then
            ditto "$BUILT_PRODUCTS_DIR/$bundle.bundle" "$helpers/$bundle.bundle"
            codesign --force "$PION_CODESIGN_TIMESTAMP" --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$helpers/$bundle.bundle"
        fi
    done
    """, name: "Embed Helpers", basedOnDependencyAnalysis: false)

/// As in Noodle's other apps: Pion already has outbound network access, so Sparkle's separate downloader
/// goes. Removing it changes the framework, so it is signed again, inside out.
let trimSparkle: TargetScript = .post(script: """
    set -euo pipefail
    sparkle="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/Sparkle.framework"
    rm -rf "$sparkle/Versions/B/XPCServices/Downloader.xpc"
    for component in "$sparkle/Versions/B/XPCServices/Installer.xpc" "$sparkle/Versions/B/Autoupdate" \\
                     "$sparkle/Versions/B/Updater.app" "$sparkle"; do
        codesign --force --options runtime "$PION_CODESIGN_TIMESTAMP" --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$component"
    done
    # Package checkouts sit beside Build/ in derived data, which archives nest deeper.
    packages="$BUILD_DIR"
    while [ ! -d "$packages/SourcePackages" ]; do
        [ "$packages" != / ] || { echo "error: no Swift package checkouts above $BUILD_DIR" >&2; exit 1; }
        packages="$(dirname "$packages")"
    done
    cp -f "$packages/SourcePackages/checkouts/Sparkle/LICENSE" \\
       "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Sparkle-LICENSE.txt"
    """, name: "Trim Sparkle", basedOnDependencyAnalysis: false)

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
        .local(path: "../../Shared/Brand"),
        .remote(url: "https://github.com/sparkle-project/Sparkle", requirement: .exact("2.9.4")),
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
                // Noodle's composer, @mention completion and dictation, the transcript's scrolling, the harness
                // choosers, the Permissions pane, and attachments with their previews, capture and annotation.
                // They depend on nothing else in Noodle's app; Pion's build fails if one ever does.
                "../../Sources/Noodle/ScrollableChatComposer.swift",
                "../../Sources/Noodle/ComposerFocusSurface.swift",
                "../../Sources/Noodle/ConversationListKeyboardNavigation.swift",
                "../../Sources/Noodle/ComposerAttachmentMenu.swift",
                "../../Sources/Noodle/ComposerNameCompletion.swift",
                "../../Sources/Noodle/KeyboardBindings.swift",
                "../../Sources/Noodle/FirstBotSetup.swift",
                "../../Sources/Noodle/KeybindingsSettingsView.swift",
                "../../Sources/Noodle/VoiceCall.swift",
                "../../Sources/Noodle/VoiceCallToolbar.swift",
                "../../Sources/Noodle/IncomingCallPanel.swift",
                "../../Sources/Noodle/VoiceRecorder.swift",
                "../../Sources/Noodle/VoiceCaptureRecovery.swift",
                "../../Sources/Noodle/VoiceInputDevice.swift",
                "../../Sources/Noodle/VoiceMessagePlayer.swift",
                "../../Sources/Noodle/VoiceMessageComposer.swift",
                "../../Sources/Noodle/HarnessChoosers.swift",
                "../../Sources/Noodle/PermissionsSettingsView.swift",
                "../../Sources/Noodle/AppUpdater.swift",
                "../../Sources/Noodle/AttachmentPreviewController.swift",
                "../../Sources/Noodle/AttachmentDrag.swift",
                "../../Sources/Noodle/ForwardAttachmentSheet.swift",
                "../../Sources/Noodle/PatchReview.swift",
                "../../Sources/Noodle/FloatingConversations.swift",
                "../../Sources/Noodle/ConversationWindowSession.swift",
                "../../Sources/Noodle/ChatSettingsView.swift",
                "../../Sources/Noodle/MessageReceivedSound.swift",
                "../../Sources/Noodle/ScenarioLauncher.swift",
                "../../Sources/Noodle/ProfileCard.swift",
                "../../Sources/Noodle/GroupsSettingsView.swift",
                "../../Sources/Noodle/AgentConfigurationFields.swift",
                "../../Sources/Noodle/ToolAssignmentList.swift",
                "../../Sources/Noodle/StoreErrorAlert.swift",
                "../../Sources/Noodle/AnnotationPopover.swift",
                "../../Sources/Noodle/AnnotationPreview.swift",
                "../../Sources/Noodle/AnnotationContent.swift",
                "../../Sources/Noodle/AnnotationCommands.swift",
                "../../Sources/Noodle/ConversationAnnotation.swift",
                "../../Sources/Noodle/ConversationAnnotationContent.swift",
                "../../Sources/Noodle/ScreenCaptureModel.swift",
                "../../Sources/Noodle/ScreenCapturePreview.swift",
                "../../Sources/Noodle/ScreenCaptureService.swift",
                "../../Sources/Noodle/CaptureAttachment.swift",
                "../../Sources/Noodle/AttachmentLayout.swift",
                "../../Sources/Noodle/SheetControls.swift",
                "../../Sources/Noodle/NoodleServices.swift",
                "../../Sources/Noodle/AttachmentInlinePreview.swift",
                "../../Sources/Noodle/MessageMarkdownCache.swift",
                "../../Sources/Noodle/MessageLinkPreview.swift",
                "../../Sources/Noodle/MessageParts.swift",
                "../../Sources/Noodle/MessageContextMenu.swift",
                "../../Sources/Noodle/SidebarTasks.swift",
                "../../Sources/Noodle/AgentNotifications.swift",
                "../../Sources/Noodle/GroupMemberPicker.swift",
                "../../Sources/Noodle/BotBudgetSheet.swift",
                "../../Sources/Noodle/DestructiveActionButton.swift",
                "../../Sources/Noodle/TranscriptScrollView.swift",
                "../../Sources/Noodle/ConversationTransition.swift",
                "../../Sources/Noodle/AgentSettingsCheckpoint.swift",
                "../../Sources/Noodle/BotFolderPicker.swift",
            ],
            resources: [
                "Support/Assets.xcassets",
                // Harness marks the shared settings draw, from Noodle's catalog.
                "../../Support/Assets.xcassets",
                .folderReference(path: "../../Support/ToolIcons"),
                "Support/AppSymbol.svg",
            ],
            entitlements: .file(path: "Support/Pion.entitlements"),
            scripts: [embedHelpers, trimSparkle],
            dependencies: [
                .package(product: "PionCore"),
                .package(product: "NoodleBrand"),
                .package(product: "NoodleCore"),
                .package(product: "NoodleRuntime"),
                .package(product: "NoodleRuntimeSettings"),
                .package(product: "NoodleAudioCapture"),
                .package(product: "NoodleVoicePeer"),
                .package(product: "NoodleSettingsUI"),
                .package(product: "HubLink"),
                .package(product: "NoodleHubClient"),
                .package(product: "NoodleWallpaper"),
                .package(product: "Sparkle"),
                .package(product: "NoodleSharing"),
                .target(name: "NoodleAgentHost"),
                .target(name: "messenger"),
                .target(name: "NoodleAppleAgent"),
                .target(name: "PionShareExtension"),
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
                    // Updates stay off unless a public release passes
                    // INFOPLIST_PREPROCESSOR_DEFINITIONS=PION_UPDATES_ENABLED=true.
                    "INFOPLIST_PREPROCESSOR_DEFINITIONS": "PION_UPDATES_ENABLED=false",
                    // The helper phases sign without a timestamp; public releases pass PION_CODESIGN_TIMESTAMP=--timestamp.
                    "PION_CODESIGN_TIMESTAMP": "--timestamp=none",
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
        .target(
            name: "PionAppTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.pdparchitect.pion.tests",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .default,
            // Test the model without launching the app or starting anyone's harnesses.
            sources: ["Tests/PionAppTests/**", "Sources/PionApp/PionModel.swift", "Sources/PionApp/MessageBodyRenderer.swift",
                      "../../Sources/Noodle/MessageMarkdownCache.swift",
                      "Sources/PionApp/WindowState.swift", "../../Sources/Noodle/SheetControls.swift", "Sources/PionApp/BackdropGames.swift",
                      "../../Sources/Noodle/AgentSettingsCheckpoint.swift"],
            dependencies: [.package(product: "NoodleCore"), .package(product: "NoodleRuntime"), .package(product: "PionCore"),
                           .package(product: "HubLink"), .package(product: "NoodleBrand"), .package(product: "NoodleRuntimeSettings")],
            settings: .settings(base: ["CODE_SIGNING_ALLOWED": "NO"])
        ),
        // Send to Pion: Noodle's Share extension, sharing only the app group it hands items over in.
        .target(
            name: "PionShareExtension",
            destinations: .macOS,
            product: .appExtension,
            bundleId: "com.pdparchitect.pion.share",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .file(path: "Support/ShareExtension-Info.plist"),
            sources: ["../../Sources/NoodleShareExtension/**"],
            entitlements: .file(path: "Support/ShareExtension.entitlements"),
            dependencies: [.package(product: "NoodleSharing")],
            settings: .settings(base: signing.merging([
                "PRODUCT_BUNDLE_IDENTIFIER": "$(PION_APP_BUNDLE_ID).share",
                "PRODUCT_NAME": "PionShare",
                "EXECUTABLE_NAME": "PionShareExtension",
            ]) { $1 })
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
