import Foundation
import ProjectDescription

// Noodle Browser as an Xcode project. The code stays in Swift packages; this describes the app bundle
// they are assembled into. Debug is Noodle Browser Dev, Release is Noodle Browser.
let version = (try? String(contentsOfFile: "VERSION", encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0.0.0"

/// The page scripts go where SwiftPM puts them, in a bundle of their own inside Resources, which is
/// where the app looks for them.
let embedPageScripts: TargetScript = .post(script: """
    set -euo pipefail
    bundle="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/NoodleBrowser_NoodleBrowser.bundle"
    rm -rf "$bundle"
    mkdir -p "$bundle"
    ditto "$SRCROOT/Sources/NoodleBrowser/Resources" "$bundle/Resources"
    """, name: "Embed Page Scripts", basedOnDependencyAnalysis: false)

/// The app already has outbound network access, so Sparkle's separate downloader goes. Removing it
/// changes the framework, so it is signed again, inside out.
let trimSparkle: TargetScript = .post(script: """
    set -euo pipefail
    sparkle="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/Sparkle.framework"
    rm -rf "$sparkle/Versions/B/XPCServices/Downloader.xpc"
    for component in "$sparkle/Versions/B/XPCServices/Installer.xpc" "$sparkle/Versions/B/Autoupdate" \\
                     "$sparkle/Versions/B/Updater.app" "$sparkle"; do
        codesign --force --options runtime "$BROWSER_CODESIGN_TIMESTAMP" --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$component"
    done
    # Package checkouts sit beside Build/ in derived data, which archives nest deeper.
    packages="$BUILD_DIR"
    while [ ! -d "$packages/SourcePackages" ]; do
        [ "$packages" != / ] || { echo "error: no Swift package checkouts above $BUILD_DIR" >&2; exit 1; }
        packages="$(dirname "$packages")"
    done
    cp "$packages/SourcePackages/checkouts/Sparkle/LICENSE" \\
       "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Sparkle-LICENSE.txt"
    """, name: "Trim Sparkle", basedOnDependencyAnalysis: false)

let project = Project(
    name: "NoodleBrowser",
    packages: [
        .local(path: "."),
        .local(path: "BrowserProtocol"),
        .local(path: "../Shared/SettingsUI"),
        .local(path: "../Shared/LaunchChecks"),
        .local(path: "../Shared/Wallpaper"),
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
            // Trim Sparkle signs without a timestamp; public releases pass BROWSER_CODESIGN_TIMESTAMP=--timestamp.
            "BROWSER_CODESIGN_TIMESTAMP": "--timestamp=none",
        ],
        configurations: [
            .debug(name: "Debug", settings: [
                "BROWSER_APP_BUNDLE_ID": "com.pdparchitect.noodle.browser.local",
                "BROWSER_APP_NAME": "Noodle Browser Dev",
                "BROWSER_GROUP_SUFFIX": "com.pdparchitect.noodle.browsers.local",
                "BROWSER_URL_SCHEME": "noodlebrowser-dev",
                "BROWSER_REFERENCE_TYPE": "com.pdparchitect.noodle.browser-reference.dev",
            ]),
            .release(name: "Release", settings: [
                "BROWSER_APP_BUNDLE_ID": "com.pdparchitect.noodle.browser",
                "BROWSER_APP_NAME": "Noodle Browser",
                "BROWSER_GROUP_SUFFIX": "com.pdparchitect.noodle.browsers",
                "BROWSER_URL_SCHEME": "noodlebrowser",
                "BROWSER_REFERENCE_TYPE": "com.pdparchitect.noodle.browser-reference",
                // Signing adds get-task-allow for the debugger; a release carries only its own entitlements.
                "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO",
            ]),
        ]
    ),
    targets: [
        .target(
            name: "NoodleBrowser",
            destinations: .macOS,
            product: .app,
            productName: "NoodleBrowser",
            bundleId: "com.pdparchitect.noodle.browser",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .file(path: "Support/Info.plist"),
            // The page scripts are not compiled; embedPageScripts ships them.
            sources: .sourceFilesList(globs: [
                .glob("Sources/NoodleBrowser/**", excluding: ["Sources/NoodleBrowser/Resources/**"]),
            ]),
            resources: ["Support/Assets.xcassets", "Support/AppSymbol.svg"],
            entitlements: .file(path: "Support/Browser.entitlements"),
            scripts: [embedPageScripts, trimSparkle],
            dependencies: [
                .package(product: "BrowserCore"),
                .package(product: "BrowserBridge"),
                .package(product: "NoodleSettingsUI"),
                .package(product: "NoodleLaunchChecks"),
                .package(product: "NoodleWallpaper"),
                .package(product: "Sparkle"),
            ],
            settings: .settings(
                base: [
                    "CODE_SIGN_STYLE": "Automatic",
                    "CODE_SIGN_IDENTITY": "Apple Development",
                    "ENABLE_HARDENED_RUNTIME": "YES",
                    "PRODUCT_BUNDLE_IDENTIFIER": "$(BROWSER_APP_BUNDLE_ID)",
                    "PRODUCT_NAME": "$(BROWSER_APP_NAME)",
                    "EXECUTABLE_NAME": "NoodleBrowser",
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "Browser",
                    // The script phases write into the app bundle.
                    "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
                    // Updates stay off unless a public release passes
                    // INFOPLIST_PREPROCESSOR_DEFINITIONS=BROWSER_UPDATES_ENABLED=true.
                    "INFOPLIST_PREPROCESS": "YES",
                    "INFOPLIST_PREPROCESSOR_DEFINITIONS": "BROWSER_UPDATES_ENABLED=false",
                    // Traditional mode keeps the "//" in URLs instead of reading it as a comment.
                    "INFOPLIST_OTHER_PREPROCESSOR_FLAGS": "-traditional",
                ],
                configurations: [
                    .debug(name: "Debug", settings: ["SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) DEBUG NOODLE_DEV_HOOKS"]),
                    .release(name: "Release"),
                ]
            )
        ),
    ]
)
