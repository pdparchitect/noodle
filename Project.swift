import Foundation
import ProjectDescription

// Noodle as an Xcode project. The code stays in Swift packages; this describes the app bundle they
// are assembled into. Debug is Noodle Dev, Release is Noodle.
let version = (try? String(contentsOfFile: "VERSION", encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0.0.0"

/// Every signed target uses the same identity, hardened, as the Agent Host requires.
let signing: SettingsDictionary = [
    "CODE_SIGN_STYLE": "Automatic",
    "CODE_SIGN_IDENTITY": "Apple Development",
    "ENABLE_HARDENED_RUNTIME": "YES",
]

/// Xcode embeds extensions and XPC services itself but not command-line tools, so the app copies its
/// helpers and the Apple harness's resource bundles into Contents/Helpers and signs them there. Xcode
/// would give a signed tool an application identifier entitlement; helpers carry none, and the Agent
/// Host applies the Apple harness's own Seatbelt policy. noodlet is Applet's CLI, signed as Applet's.
let embedHelpers: TargetScript = .post(script: """
    set -euo pipefail
    helpers="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
    mkdir -p "$helpers"
    sign() { codesign --force --options runtime "$NOODLE_CODESIGN_TIMESTAMP" --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$@"; }
    # A debug link also searches the package frameworks in derived data; the app ships its own.
    install_name_tool -delete_rpath "$BUILT_PRODUCTS_DIR/PackageFrameworks" "$TARGET_BUILD_DIR/$EXECUTABLE_PATH" 2>/dev/null || true
    for tool in messenger noodlet NoodleAppleAgent; do
        ditto "$BUILT_PRODUCTS_DIR/$tool" "$helpers/$tool"
    done
    sign "$helpers/messenger"
    sign --identifier "$NOODLE_APPLET_CLI_ID" "$helpers/noodlet"
    sign --identifier "$PRODUCT_BUNDLE_IDENTIFIER.apple-agent" "$helpers/NoodleAppleAgent"
    for bundle in mlx-swift_Cmlx swift-transformers_Hub swift-crypto_Crypto; do
        if [ -d "$BUILT_PRODUCTS_DIR/$bundle.bundle" ]; then
            rm -rf "$helpers/$bundle.bundle"
            ditto "$BUILT_PRODUCTS_DIR/$bundle.bundle" "$helpers/$bundle.bundle"
            codesign --force "$NOODLE_CODESIGN_TIMESTAMP" --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$helpers/$bundle.bundle"
        fi
    done
    """, name: "Embed Helpers", basedOnDependencyAnalysis: false)

/// Tool extensions bind to Noodle's extension point, which ToolExtensionDiscovery.swift declares.
/// Xcode leaves the declaration in the app's compiled constant values; this writes it where macOS
/// looks, Contents/Extensions/Noodle.appexpt, as `<bundle identifier>.tool`.
let extractExtensionPoint: TargetScript = .post(script: """
    set -euo pipefail
    extensions="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Extensions"
    mkdir -p "$extensions"
    # Releases build one architecture, so ARCHS names the one folder of object files.
    find "$OBJECT_FILE_DIR_normal/$ARCHS" -name '*.swiftconstvalues' -print0 |
        xargs -0 xcrun exutil extract-extension-points --bundle-identifier "$PRODUCT_BUNDLE_IDENTIFIER" \\
            --output "$extensions/Noodle.appexpt"
    [ "$(/usr/libexec/PlistBuddy -c "Print :$PRODUCT_BUNDLE_IDENTIFIER.tool:EXExtensionPointName" "$extensions/Noodle.appexpt")" = tool ]
    """, name: "Extract Extension Point", basedOnDependencyAnalysis: false)

/// The app already has outbound network access, so Sparkle's separate downloader goes. Removing it
/// changes the framework, so it is signed again, inside out. Every dependency's licence ships too.
let trimSparkle: TargetScript = .post(script: """
    set -euo pipefail
    sparkle="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/Sparkle.framework"
    rm -rf "$sparkle/Versions/B/XPCServices/Downloader.xpc"
    for component in "$sparkle/Versions/B/XPCServices/Installer.xpc" "$sparkle/Versions/B/Autoupdate" \\
                     "$sparkle/Versions/B/Updater.app" "$sparkle"; do
        codesign --force --options runtime "$NOODLE_CODESIGN_TIMESTAMP" --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$component"
    done
    # Package checkouts sit beside Build/ in derived data, which archives nest deeper.
    packages="$BUILD_DIR"
    while [ ! -d "$packages/SourcePackages" ]; do
        [ "$packages" != / ] || { echo "error: no Swift package checkouts above $BUILD_DIR" >&2; exit 1; }
        packages="$(dirname "$packages")"
    done
    resources="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
    for dependency in "$packages/SourcePackages/checkouts"/*; do
        for license in LICENSE LICENSE.txt; do
            if [ -f "$dependency/$license" ]; then cp -f "$dependency/$license" "$resources/$(basename "$dependency")-LICENSE.txt"; break; fi
        done
    done
    cp "$packages/SourcePackages/checkouts/mlx-swift-lm/Libraries/MLXCXGrammar/xgrammar/LICENSE" "$resources/xgrammar-LICENSE.txt"
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

/// A tool extension in Tools/NAME, bound to Noodle's tool extension point. See Tools/AGENTS.md.
func toolExtension(_ name: String) -> Target {
    let provider = "Noodle\(name)Tools"
    return .target(
        name: "\(provider)Extension",
        destinations: .macOS,
        product: .extensionKitExtension,
        bundleId: "com.pdparchitect.noodle.tools.\(name.lowercased())",
        deploymentTargets: .macOS("26.0"),
        infoPlist: .file(path: "Tools/\(name)/Info.plist"),
        sources: ["Tools/\(name)/Sources/\(provider)Extension/**"],
        entitlements: .file(path: "Tools/\(name)/Extension.entitlements"),
        dependencies: [.package(product: "NoodleCore"), .package(product: provider)],
        settings: .settings(base: signing.merging([
            "PRODUCT_BUNDLE_IDENTIFIER": "$(NOODLE_APP_BUNDLE_ID).tools.\(name.lowercased())",
            "PRODUCT_NAME": .string("Noodle\(name)Tools"),
            // The bundle keeps the tool's name; the module must not take its provider's.
            "PRODUCT_MODULE_NAME": .string("\(provider)Extension"),
            "EXECUTABLE_NAME": .string("\(provider)Extension"),
        ]) { $1 })
    )
}

let project = Project(
    name: "Noodle",
    packages: [
        .local(path: "."),
        .local(path: "Applet"),
        .local(path: "Applet/Protocol"),
        .local(path: "Shared/SettingsUI"),
        .local(path: "Shared/LaunchChecks"),
        .local(path: "Shared/Wallpaper"),
        .local(path: "Computer/Bridge"),
        .local(path: "Browser/BrowserProtocol"),
        .remote(url: "https://github.com/sparkle-project/Sparkle", requirement: .exact("2.9.4")),
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
            // The helper phases sign without a timestamp; public releases pass NOODLE_CODESIGN_TIMESTAMP=--timestamp.
            "NOODLE_CODESIGN_TIMESTAMP": "--timestamp=none",
            // Signing adds get-task-allow for the debugger. Only the Dev app takes it; the Agent Host and
            // extensions carry exactly their own entitlements in every build.
            "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO",
        ],
        configurations: [
            .debug(name: "Debug", settings: [
                "NOODLE_APP_BUNDLE_ID": "com.pdparchitect.noodle.local",
                "NOODLE_APP_NAME": "Noodle Dev",
                "NOODLE_URL_SCHEME": "noodle-dev",
                "NOODLE_GOOGLE_SCHEME": "com.googleusercontent.apps.183234845746-9homesnd85b490uj2ak37rpk0svtveap",
                // Noodle Dev talks to the Dev companions only.
                "NOODLE_COMPANION_SUFFIX": ".local",
                "NOODLE_APPLET_CLI_ID": "com.pdparchitect.noodle.applet.local.cli",
            ]),
            .release(name: "Release", settings: [
                "NOODLE_APP_BUNDLE_ID": "com.pdparchitect.noodle",
                "NOODLE_APP_NAME": "Noodle",
                "NOODLE_URL_SCHEME": "noodle",
                "NOODLE_GOOGLE_SCHEME": "com.googleusercontent.apps.183234845746-flond96hao8g0cll1boruegemodo9fe5",
                "NOODLE_COMPANION_SUFFIX": "",
                "NOODLE_APPLET_CLI_ID": "com.pdparchitect.noodle.applet.cli",
            ]),
        ]
    ),
    targets: [
        .target(
            name: "Noodle",
            destinations: .macOS,
            product: .app,
            bundleId: "com.pdparchitect.noodle",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .file(path: "Support/Info.plist"),
            sources: ["Sources/Noodle/**"],
            resources: [
                "Support/Assets.xcassets",
                .folderReference(path: "Support/ToolIcons"),
                .folderReference(path: "Support/ThirdParty"),
            ],
            entitlements: .file(path: "Support/Noodle.entitlements"),
            scripts: [extractExtensionPoint, embedHelpers, trimSparkle],
            dependencies: [
                .package(product: "BrowserBridge"),
                .package(product: "NoodleCore"),
                .package(product: "NoodleBrowserTools"),
                .package(product: "NoodleCalendarTools"),
                .package(product: "NoodleComputerTools"),
                .package(product: "NoodleRemindersTools"),
                .package(product: "NoodleMCP"),
                .package(product: "NoodleSharing"),
                .package(product: "NoodleRuntime"),
                .package(product: "NoodleRuntimeSettings"),
                .package(product: "NoodleAgentBridge"),
                .package(product: "NoodleAudioCapture"),
                .package(product: "NoodleLaunchChecks"),
                .package(product: "NoodleSettingsUI"),
                .package(product: "NoodleWallpaper"),
                .package(product: "Sparkle"),
                .package(product: "ComputerBridge"),
                .target(name: "NoodleAgentHost"),
                .target(name: "NoodleShareExtension"),
                .target(name: "NoodleVisionToolsExtension"),
                .target(name: "NoodleMapsToolsExtension"),
                .target(name: "NoodleBrowserToolsExtension"),
                .target(name: "NoodleComputerToolsExtension"),
                .target(name: "messenger"),
                .target(name: "noodlet"),
                .target(name: "NoodleAppleAgent"),
            ],
            settings: .settings(
                base: signing.merging([
                    "PRODUCT_BUNDLE_IDENTIFIER": "$(NOODLE_APP_BUNDLE_ID)",
                    "PRODUCT_NAME": "$(NOODLE_APP_NAME)",
                    "EXECUTABLE_NAME": "Noodle",
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
                    // The script phases write into the app bundle.
                    "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
                    // Updates stay off unless a public release passes
                    // INFOPLIST_PREPROCESSOR_DEFINITIONS=NOODLE_UPDATES_ENABLED=true.
                    "INFOPLIST_PREPROCESS": "YES",
                    "INFOPLIST_PREPROCESSOR_DEFINITIONS": "NOODLE_UPDATES_ENABLED=false",
                    // Traditional mode keeps the "//" in URLs instead of reading it as a comment.
                    "INFOPLIST_OTHER_PREPROCESSOR_FLAGS": "-traditional",
                ]) { $1 },
                configurations: [
                    .debug(name: "Debug", settings: [
                        "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) DEBUG NOODLE_DEV_HOOKS",
                        "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "YES",
                        // Scenarios and the smoke test read the Dev app's executable, so its code stays in it.
                        "ENABLE_DEBUG_DYLIB": "NO",
                    ]),
                    .release(name: "Release"),
                ]
            )
        ),
        // Launches harnesses under their sandbox. It accepts Noodle alone, and Noodle accepts it alone.
        .target(
            name: "NoodleAgentHost",
            destinations: .macOS,
            product: .xpc,
            bundleId: "com.pdparchitect.noodle.agent-host",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .file(path: "Support/AgentHost-Info.plist"),
            sources: ["Sources/NoodleAgentHost/**"],
            dependencies: [.package(product: "NoodleCore"), .package(product: "NoodleAgentBridge")],
            settings: .settings(base: signing.merging([
                "PRODUCT_BUNDLE_IDENTIFIER": "$(NOODLE_APP_BUNDLE_ID).agent-host",
                "PRODUCT_NAME": "NoodleAgentHost",
            ]) { $1 })
        ),
        // Send to Noodle, sharing only the app group it hands items over in.
        .target(
            name: "NoodleShareExtension",
            destinations: .macOS,
            product: .appExtension,
            bundleId: "com.pdparchitect.noodle.share",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .file(path: "Support/ShareExtension-Info.plist"),
            sources: ["Sources/NoodleShareExtension/**"],
            entitlements: .file(path: "Support/ShareExtension.entitlements"),
            dependencies: [.package(product: "NoodleSharing")],
            settings: .settings(base: signing.merging([
                "PRODUCT_BUNDLE_IDENTIFIER": "$(NOODLE_APP_BUNDLE_ID).share",
                "PRODUCT_NAME": "NoodleShare",
                "EXECUTABLE_NAME": "NoodleShareExtension",
            ]) { $1 })
        ),
        toolExtension("Vision"),
        toolExtension("Maps"),
        toolExtension("Browser"),
        toolExtension("Computer"),
        helper("messenger", sources: ["Sources/NoodleMessenger/**"],
               dependencies: [.package(product: "NoodleCore"), .package(product: "NoodleToolScripting")]),
        // main.swift declares @main, which SwiftPM compiles as a library file; Xcode must be told.
        helper("noodlet", sources: ["Applet/Sources/NoodletCLI/**"],
               dependencies: [.package(product: "AppletCore"), .package(product: "AppletBridge")],
               settings: ["OTHER_SWIFT_FLAGS": "$(inherited) -parse-as-library"]),
        // Its Info.plist is linked in as the root package does: an Info.plist Xcode builds itself would
        // make it add an application identifier entitlement, which the harness must not carry.
        helper("NoodleAppleAgent", sources: ["Sources/NoodleAppleAgent/**"],
               dependencies: [.package(product: "NoodleCore"), .package(product: "NoodleAppleRuntime")],
               settings: [
                   "OTHER_LDFLAGS": "$(inherited) -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker $(SRCROOT)/Support/AppleAgent-Info.plist",
               ]),
    ]
)
