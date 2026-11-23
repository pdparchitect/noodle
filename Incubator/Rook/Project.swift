import Foundation
import ProjectDescription

// Rook as an Xcode project. Rook is its own app on Noodle's core and runtime; besides the shared
// packages it compiles a few self-contained files straight from Noodle's app, the composer, dictation and
// the transcript's scrolling, as Noodle Hub compiles the Agent Host. Debug is Rook Dev, Release is Rook.
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
    sign() { codesign --force --options runtime "$ROOK_CODESIGN_TIMESTAMP" --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$@"; }
    install_name_tool -delete_rpath "$BUILT_PRODUCTS_DIR/PackageFrameworks" "$TARGET_BUILD_DIR/$EXECUTABLE_PATH" 2>/dev/null || true
    for tool in messenger NoodleAppleAgent; do
        ditto "$BUILT_PRODUCTS_DIR/$tool" "$helpers/$tool"
    done
    sign "$helpers/messenger"
    sign --identifier "$PRODUCT_BUNDLE_IDENTIFIER.apple-agent" "$helpers/NoodleAppleAgent"
    for bundle in mlx-swift_Cmlx swift-transformers_Hub swift-crypto_Crypto; do
        if [ -d "$BUILT_PRODUCTS_DIR/$bundle.bundle" ]; then
            ditto "$BUILT_PRODUCTS_DIR/$bundle.bundle" "$helpers/$bundle.bundle"
            codesign --force "$ROOK_CODESIGN_TIMESTAMP" --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$helpers/$bundle.bundle"
        fi
    done
    """, name: "Embed Helpers", basedOnDependencyAnalysis: false)

/// As in Noodle's other apps: Rook already has outbound network access, so Sparkle's separate downloader
/// goes. Removing it changes the framework, so it is signed again, inside out.
let trimSparkle: TargetScript = .post(script: """
    set -euo pipefail
    sparkle="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/Sparkle.framework"
    rm -rf "$sparkle/Versions/B/XPCServices/Downloader.xpc"
    for component in "$sparkle/Versions/B/XPCServices/Installer.xpc" "$sparkle/Versions/B/Autoupdate" \\
                     "$sparkle/Versions/B/Updater.app" "$sparkle"; do
        codesign --force --options runtime "$ROOK_CODESIGN_TIMESTAMP" --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$component"
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

/// Missions' computers run inside Rook, on Noodle Computer's engine: Linux computers boot its pinned kernel,
/// so a build refuses any other, and their file helper is built for the guest. Windows and this Mac are left out.
let computerRuntime: TargetScript = .post(script: """
    set -euo pipefail
    kernel="$SRCROOT/../../Computer/Resources/Runtime/vmlinux-arm64"
    if [ ! -f "$kernel" ] || [ "$(stat -f %z "$kernel")" -lt 1000000 ]; then
        echo "error: Missing Noodle Computer's runtime kernel. See Computer/README.md (git lfs pull)." >&2; exit 1
    fi
    [ "$(shasum -a 256 "$kernel" | awk '{print $1}')" = 08c33f0a0580e92a7ed08e4d40d593a7dd4ca738ee5906b06f329d973d37e616 ] || {
        echo "error: Noodle Computer's runtime kernel does not match its pinned checksum." >&2; exit 1
    }
    export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/local/go/bin"
    command -v go >/dev/null || { echo "error: Building Rook requires Go for the Linux guest file helper." >&2; exit 1; }
    export GOCACHE="$DERIVED_FILE_DIR/GoCache"
    CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags='-s -w' \\
        -o "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Runtime/noodle-files" "$SRCROOT/../../Computer/GuestFiles/main.go"
    """, name: "Computer Runtime", basedOnDependencyAnalysis: false)

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
    name: "Rook",
    packages: [
        .local(path: "."),
        .local(path: "../.."),
        .local(path: "../../Shared/SettingsUI"),
        .local(path: "../../Shared/HubLink"),
        .local(path: "../../Shared/Wallpaper"),
        .local(path: "../../Shared/Brand"),
        .local(path: "../../Computer"),
        .local(path: "../../Computer/Bridge"),
        .local(path: "../../Computer/LocalMac"),
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
                "ROOK_APP_BUNDLE_ID": "com.pdparchitect.rook.local",
                "ROOK_APP_NAME": "Rook Dev",
                "ROOK_URL_SCHEME": "rook-dev",
            ]),
            .release(name: "Release", settings: [
                "ROOK_APP_BUNDLE_ID": "com.pdparchitect.rook",
                "ROOK_APP_NAME": "Rook",
                "ROOK_URL_SCHEME": "rook",
            ]),
        ]
    ),
    targets: [
        .target(
            name: "Rook",
            destinations: .macOS,
            product: .app,
            productName: "Rook",
            bundleId: "com.pdparchitect.rook",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .file(path: "Support/Info.plist"),
            sources: [
                "Sources/RookApp/**",
                // Noodle's composer, @mention completion and dictation, the transcript's scrolling, the harness
                // choosers, the Permissions pane, and attachments with their previews, capture and annotation.
                // They depend on nothing else in Noodle's app; Rook's build fails if one ever does.
                "../../Sources/Noodle/ScrollableChatComposer.swift",
                "../../Sources/Noodle/ExternalEventPresentation.swift",
                "../../Sources/Noodle/IncomingCallPanel.swift",
                "../../Sources/Noodle/AppIdentity.swift",
                "../../Sources/Noodle/ComposerFocusSurface.swift",
                "../../Sources/Noodle/ConversationListKeyboardNavigation.swift",
                "../../Sources/Noodle/ComposerAttachmentMenu.swift",
                "../../Sources/Noodle/ComposerNameCompletion.swift",
                "../../Sources/Noodle/ComposerSendButton.swift",
                "../../Sources/Noodle/KeyboardBindings.swift",
                "../../Sources/Noodle/FirstBotSetup.swift",
                "../../Sources/Noodle/KeybindingsSettingsView.swift",
                "../../Sources/Noodle/VoiceCall.swift",
                "../../Sources/Noodle/VoiceCallToolbar.swift",
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
                "../../Sources/Noodle/ScenarioFilm.swift",
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
                "../../Sources/Noodle/MessageBlocksView.swift",
                "../../Sources/Noodle/ConversationAnnotationContent.swift",
                "../../Sources/Noodle/ScreenCaptureModel.swift",
                "../../Sources/Noodle/ScreenCapturePreview.swift",
                "../../Sources/Noodle/ScreenCaptureService.swift",
                "../../Sources/Noodle/CaptureAttachment.swift",
                "../../Sources/Noodle/AttachmentLayout.swift",
                "../../Sources/Noodle/SheetControls.swift",
                "../../Sources/Noodle/NoodleServices.swift",
                "../../Sources/Noodle/IntentSupport.swift",
                "../../Sources/Noodle/AttachmentInlinePreview.swift",
                "../../Sources/Noodle/MessageMarkdownCache.swift",
                "../../Sources/Noodle/MessageLinkPreview.swift",
                "../../Sources/Noodle/MessageParts.swift",
                "../../Sources/Noodle/MessageContextMenu.swift",
                "../../Sources/Noodle/SidebarItemLayout.swift",
                "../../Sources/Noodle/SidebarTasks.swift",
                "../../Sources/Noodle/AgentNotifications.swift",
                "../../Sources/Noodle/GroupMemberPicker.swift",
                "../../Sources/Noodle/BotBudgetSheet.swift",
                "../../Sources/Noodle/DestructiveActionButton.swift",
                "../../Sources/Noodle/TranscriptScrollView.swift",
                "../../Sources/Noodle/ConversationTransition.swift",
                "../../Sources/Noodle/AgentSettingsCheckpoint.swift",
                "../../Sources/Noodle/BotFolderPicker.swift",
                // Noodle Computer's views for making, showing and changing a computer, over the engine Rook runs.
                "../../Computer/Sources/NoodleComputer/ComputerViews.swift",
                "../../Computer/Sources/NoodleComputer/ComputerAppearanceView.swift",
                "../../Computer/Sources/NoodleComputer/SSHComputerView.swift",
                "../../Computer/Sources/NoodleComputer/ComputerFilesView.swift",
                "../../Computer/Sources/NoodleComputer/ComputerFileIcons.swift",
                "../../Computer/Sources/NoodleComputer/ComputerFileSearchField.swift",
                "../../Computer/Sources/NoodleComputer/FileDropDestination.swift",
                "../../Computer/Sources/NoodleComputer/ComputerImageUpdateButton.swift",
                "../../Computer/Sources/NoodleComputer/LocalMacView.swift",
            ],
            resources: [
                "Support/Assets.xcassets",
                // Harness marks the shared settings draw, from Noodle's catalog.
                "../../Support/Assets.xcassets",
                .folderReference(path: "../../Support/ToolIcons"),
                "Support/AppSymbol.svg",
                .folderReference(path: "../../Computer/Resources/Runtime"),
                "../../Computer/Support/KERNEL-NOTICE.txt",
            ],
            entitlements: .file(path: "Support/Rook.entitlements"),
            scripts: [embedHelpers, trimSparkle, computerRuntime],
            dependencies: [
                .package(product: "RookCore"),
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
                .package(product: "ComputerEngine"),
                .package(product: "ComputerCore"),
                .package(product: "ComputerBridge"),
                .package(product: "NoodleComputerTools"),
                .package(product: "LocalMacCore"),
                .target(name: "NoodleAgentHost"),
                .target(name: "messenger"),
                .target(name: "NoodleAppleAgent"),
                .target(name: "RookShareExtension"),
            ],
            settings: .settings(
                base: signing.merging([
                    "PRODUCT_BUNDLE_IDENTIFIER": "$(ROOK_APP_BUNDLE_ID)",
                    "PRODUCT_NAME": "$(ROOK_APP_NAME)",
                    "EXECUTABLE_NAME": "Rook",
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "RookIcon",
                    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
                    "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
                    "INFOPLIST_PREPROCESS": "YES",
                    // Updates stay off unless a public release passes
                    // INFOPLIST_PREPROCESSOR_DEFINITIONS=ROOK_UPDATES_ENABLED=true.
                    "INFOPLIST_PREPROCESSOR_DEFINITIONS": "ROOK_UPDATES_ENABLED=false",
                    // The helper phases sign without a timestamp; public releases pass ROOK_CODESIGN_TIMESTAMP=--timestamp.
                    "ROOK_CODESIGN_TIMESTAMP": "--timestamp=none",
                    "INFOPLIST_OTHER_PREPROCESSOR_FLAGS": "-traditional",
                ]) { $1 },
                configurations: [
                    .debug(name: "Debug", settings: [
                        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) DEBUG ROOK_DEV_HOOKS NOODLE_DEV_HOOKS",
                        "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "YES",
                        "ENABLE_DEBUG_DYLIB": "NO",
                    ]),
                    .release(name: "Release"),
                ]
            )
        ),
        .target(
            name: "RookAppTests",
            destinations: .macOS,
            product: .unitTests,
            bundleId: "com.pdparchitect.rook.tests",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .default,
            // Test the model without launching the app or starting anyone's harnesses.
            sources: ["Tests/RookAppTests/**", "Sources/RookApp/RookModel.swift", "Sources/RookApp/MessageBodyRenderer.swift",
                      "../../Sources/Noodle/MessageMarkdownCache.swift",
                      "Sources/RookApp/WindowState.swift", "../../Sources/Noodle/SheetControls.swift", "Sources/RookApp/BackdropGames.swift",
                      "Sources/RookApp/MissionGraphView.swift",
                      "../../Sources/Noodle/AgentSettingsCheckpoint.swift"],
            dependencies: [.package(product: "NoodleCore"), .package(product: "NoodleRuntime"), .package(product: "RookCore"),
                           .package(product: "HubLink"), .package(product: "NoodleBrand"), .package(product: "NoodleRuntimeSettings")],
            settings: .settings(base: ["CODE_SIGNING_ALLOWED": "NO"])
        ),
        // Send to Rook: Noodle's Share extension, sharing only the app group it hands items over in.
        .target(
            name: "RookShareExtension",
            destinations: .macOS,
            product: .appExtension,
            bundleId: "com.pdparchitect.rook.share",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .file(path: "Support/ShareExtension-Info.plist"),
            sources: ["../../Sources/NoodleShareExtension/**"],
            entitlements: .file(path: "Support/ShareExtension.entitlements"),
            dependencies: [.package(product: "NoodleSharing")],
            settings: .settings(base: signing.merging([
                "PRODUCT_BUNDLE_IDENTIFIER": "$(ROOK_APP_BUNDLE_ID).share",
                "PRODUCT_NAME": "RookShare",
                "EXECUTABLE_NAME": "RookShareExtension",
            ]) { $1 })
        ),
        // Launches harnesses under their sandbox. It accepts Rook alone, and Rook accepts it alone.
        .target(
            name: "NoodleAgentHost",
            destinations: .macOS,
            product: .xpc,
            bundleId: "com.pdparchitect.rook.agent-host",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleName": "Rook Agent Host",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "XPCService": ["ServiceType": "Application", "JoinExistingSession": true],
                "NoodleSigningTeam": "$(DEVELOPMENT_TEAM)",
                "NoodleApplicationIdentifier": "$(ROOK_APP_BUNDLE_ID)",
                "NoodleAgentHostService": "$(ROOK_APP_BUNDLE_ID).agent-host",
                // Restricted agents are siloed, reaching only their harness's own services.
                "NoodleHarnessSilo": true,
            ]),
            sources: ["../../Sources/NoodleAgentHost/**"],
            dependencies: [.package(product: "NoodleCore"), .package(product: "NoodleAgentBridge")],
            settings: .settings(base: signing.merging([
                "PRODUCT_BUNDLE_IDENTIFIER": "$(ROOK_APP_BUNDLE_ID).agent-host",
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
