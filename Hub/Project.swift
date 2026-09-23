import Foundation
import ProjectDescription

// Noodle Hub as an Xcode project. The code stays in Swift packages; this describes the app bundle
// they are assembled into. Debug is Noodle Hub Dev, Release is Noodle Hub.
let version = (try? String(contentsOfFile: "VERSION", encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0.0.0"

/// Every target signs with the same identity, hardened, as the Agent Host requires.
let signing: SettingsDictionary = [
    "CODE_SIGN_STYLE": "Automatic",
    "CODE_SIGN_IDENTITY": "Apple Development",
    "ENABLE_HARDENED_RUNTIME": "YES",
]

/// Xcode embeds frameworks and XPC services itself but not command-line tools, so the app copies its
/// helpers and the Apple harness's resource bundles into Contents/Helpers and signs them there with the
/// app's identity. Xcode would give a signed tool an application identifier entitlement; helpers carry
/// none, and the Agent Host applies the Apple harness's own Seatbelt policy. Xcode then signs the app.
let embedHelpers: TargetScript = .post(script: """
    set -euo pipefail
    helpers="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
    mkdir -p "$helpers"
    for tool in messenger NoodleAppleAgent; do
        ditto "$BUILT_PRODUCTS_DIR/$tool" "$helpers/$tool"
    done
    codesign --force --options runtime "$HUB_CODESIGN_TIMESTAMP" --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$helpers/messenger"
    codesign --force --options runtime "$HUB_CODESIGN_TIMESTAMP" --sign "$EXPANDED_CODE_SIGN_IDENTITY" \
        --identifier "$HUB_APP_BUNDLE_ID.apple-agent" "$helpers/NoodleAppleAgent"
    for bundle in mlx-swift_Cmlx swift-transformers_Hub swift-crypto_Crypto; do
        if [ -d "$BUILT_PRODUCTS_DIR/$bundle.bundle" ]; then
            rm -rf "$helpers/$bundle.bundle"
            ditto "$BUILT_PRODUCTS_DIR/$bundle.bundle" "$helpers/$bundle.bundle"
            codesign --force "$HUB_CODESIGN_TIMESTAMP" --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$helpers/$bundle.bundle"
        fi
    done
    """, name: "Embed Helpers", basedOnDependencyAnalysis: false)

/// The app already has outbound network access, so Sparkle's separate downloader goes, as in the
/// other apps. Removing it changes the framework, so it is signed again, inside out.
let trimSparkle: TargetScript = .post(script: """
    set -euo pipefail
    sparkle="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/Sparkle.framework"
    rm -rf "$sparkle/Versions/B/XPCServices/Downloader.xpc"
    for component in "$sparkle/Versions/B/XPCServices/Installer.xpc" "$sparkle/Versions/B/Autoupdate" \
                     "$sparkle/Versions/B/Updater.app" "$sparkle"; do
        codesign --force --options runtime "$HUB_CODESIGN_TIMESTAMP" --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$component"
    done
    # Package checkouts sit beside Build/ in derived data, which archives nest deeper.
    packages="$BUILD_DIR"
    while [ ! -d "$packages/SourcePackages" ]; do
        [ "$packages" != / ] || { echo "error: no Swift package checkouts above $BUILD_DIR" >&2; exit 1; }
        packages="$(dirname "$packages")"
    done
    cp "$packages/SourcePackages/checkouts/Sparkle/LICENSE" \
       "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Sparkle-LICENSE.txt"
    """, name: "Trim Sparkle", basedOnDependencyAnalysis: false)

/// A command-line helper the app runs from Contents/Helpers.
func helper(_ name: String, sources: SourceFilesList, bundleID: String,
            dependencies: [TargetDependency], settings: SettingsDictionary = [:]) -> Target {
    .target(
        name: name,
        destinations: .macOS,
        product: .commandLineTool,
        bundleId: bundleID,
        deploymentTargets: .macOS("26.0"),
        sources: sources,
        dependencies: dependencies,
        // The app signs its helpers when it embeds them; see embedHelpers.
        settings: .settings(base: ["PRODUCT_BUNDLE_IDENTIFIER": .string(bundleID),
                                   "CODE_SIGNING_ALLOWED": "NO"]
            .merging(settings) { $1 })
    )
}

let project = Project(
    name: "NoodleHub",
    packages: [
        .local(path: "."),
        .local(path: ".."),
        .local(path: "../Shared/SettingsUI"),
        .remote(url: "https://github.com/sparkle-project/Sparkle", requirement: .exact("2.9.4")),
    ],
    settings: .settings(
        base: [
            "DEVELOPMENT_TEAM": "S8VNVK39LH",
            "MACOSX_DEPLOYMENT_TARGET": "26.0",
            "SWIFT_VERSION": "5",
            "MARKETING_VERSION": .string(version),
            "CURRENT_PROJECT_VERSION": .string(version),
        ],
        configurations: [
            .debug(name: "Debug", settings: [
                "HUB_APP_BUNDLE_ID": "com.pdparchitect.noodle.hub.local",
                "HUB_APP_NAME": "Noodle Hub Dev",
            ]),
            .release(name: "Release", settings: [
                "HUB_APP_BUNDLE_ID": "com.pdparchitect.noodle.hub",
                "HUB_APP_NAME": "Noodle Hub",
                // Signing adds get-task-allow for the debugger; a release carries only its own entitlements.
                "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO",
            ]),
        ]
    ),
    targets: [
        .target(
            name: "NoodleHub",
            destinations: .macOS,
            product: .app,
            productName: "NoodleHub",
            bundleId: "com.pdparchitect.noodle.hub",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .file(path: "Support/Info.plist"),
            sources: ["Sources/NoodleHub/**"],
            resources: [
                "Support/Assets.xcassets",
                // Harness marks the shared settings draw, from Noodle's catalog.
                "../Support/Assets.xcassets",
                .folderReference(path: "../Support/ToolIcons"),
                "Support/AppSymbol.svg",
            ],
            // Includes Sparkle's two installer endpoints for this app's identifier.
            entitlements: .file(path: "Support/Hub.entitlements"),
            scripts: [embedHelpers, trimSparkle],
            dependencies: [
                .package(product: "HubCore"),
                .package(product: "NoodleRuntimeSettings"),
                .package(product: "NoodleSettingsUI"),
                .package(product: "Sparkle"),
                .target(name: "NoodleAgentHost"),
                .target(name: "messenger"),
                .target(name: "NoodleAppleAgent"),
            ],
            settings: .settings(base: signing.merging([
                "PRODUCT_BUNDLE_IDENTIFIER": "$(HUB_APP_BUNDLE_ID)",
                "PRODUCT_NAME": "$(HUB_APP_NAME)",
                "EXECUTABLE_NAME": "NoodleHub",
                // Embed Helpers writes into the app bundle.
                "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
                "ASSETCATALOG_COMPILER_APPICON_NAME": "HubIcon",
                // The helper phases sign without a timestamp; public releases pass HUB_CODESIGN_TIMESTAMP=--timestamp.
                "HUB_CODESIGN_TIMESTAMP": "--timestamp=none",
                // Updates stay off unless a public release passes
                // INFOPLIST_PREPROCESSOR_DEFINITIONS=HUB_UPDATES_ENABLED=true.
                "INFOPLIST_PREPROCESS": "YES",
                "INFOPLIST_PREPROCESSOR_DEFINITIONS": "HUB_UPDATES_ENABLED=false",
                // Traditional mode keeps the "//" in URLs instead of reading it as a comment.
                "INFOPLIST_OTHER_PREPROCESSOR_FLAGS": "-traditional",
            ]) { $1 })
        ),
        // Launches harnesses under their sandbox. It accepts the Hub alone, and the Hub accepts it alone.
        .target(
            name: "NoodleAgentHost",
            destinations: .macOS,
            product: .xpc,
            bundleId: "com.pdparchitect.noodle.hub.agent-host",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleName": "Noodle Agent Host",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "XPCService": ["ServiceType": "Application", "JoinExistingSession": true],
                "NoodleSigningTeam": "$(DEVELOPMENT_TEAM)",
                "NoodleApplicationIdentifier": "$(HUB_APP_BUNDLE_ID)",
                "NoodleAgentHostService": "$(HUB_APP_BUNDLE_ID).agent-host",
            ]),
            sources: ["../Sources/NoodleAgentHost/**"],
            dependencies: [.package(product: "NoodleCore"), .package(product: "NoodleAgentBridge")],
            settings: .settings(base: signing.merging([
                "PRODUCT_BUNDLE_IDENTIFIER": "$(HUB_APP_BUNDLE_ID).agent-host",
                "PRODUCT_NAME": "NoodleAgentHost",
            ]) { $1 })
        ),
        helper("messenger", sources: ["../Sources/NoodleMessenger/**"], bundleID: "messenger",
               dependencies: [.package(product: "NoodleCore"), .package(product: "NoodleToolScripting")]),
        // The Agent Host applies this helper's own Seatbelt policy before exec.
        // Its Info.plist is linked in as the root package does: an Info.plist Xcode builds itself would
        // make it add an application identifier entitlement, which the harness must not carry.
        helper("NoodleAppleAgent", sources: ["../Sources/NoodleAppleAgent/**"],
               bundleID: "NoodleAppleAgent",
               dependencies: [.package(product: "NoodleCore"), .package(product: "NoodleAppleRuntime")],
               settings: [
                   "OTHER_LDFLAGS": "$(inherited) -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker $(SRCROOT)/../Support/AppleAgent-Info.plist",
               ]),
    ]
)
