import Foundation
import ProjectDescription

// Noodle Applet as an Xcode project. The code stays in Swift packages; this describes the app bundle
// they are assembled into. Debug is Noodle Applet Dev, Release is Noodle Applet.
let version = (try? String(contentsOfFile: "VERSION", encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0.0.0"

/// Every signed target uses the same identity, hardened.
let signing: SettingsDictionary = [
    "CODE_SIGN_STYLE": "Automatic",
    "CODE_SIGN_IDENTITY": "Apple Development",
    "ENABLE_HARDENED_RUNTIME": "YES",
]

/// Xcode embeds extensions and XPC services itself but not command-line tools, so the app copies the
/// noodlet CLI into Contents/Helpers and signs it there with its own identifier and no entitlements.
/// A development build's bundled examples use the development document extension.
let embedHelpers: TargetScript = .post(script: """
    set -euo pipefail
    helpers="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
    mkdir -p "$helpers"
    ditto "$BUILT_PRODUCTS_DIR/noodlet" "$helpers/noodlet"
    codesign --force --options runtime "$APPLET_CODESIGN_TIMESTAMP" --sign "$EXPANDED_CODE_SIGN_IDENTITY" \\
        --identifier "$PRODUCT_BUNDLE_IDENTIFIER.cli" "$helpers/noodlet"
    if [ "$APPLET_DOCUMENT_EXTENSION" != noodlet ]; then
        for example in "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Resources/Examples"/*.noodlet; do
            [ -e "$example" ] && mv "$example" "${example%.noodlet}.$APPLET_DOCUMENT_EXTENSION"
        done
    fi
    """, name: "Embed Helpers", basedOnDependencyAnalysis: false)

/// Noodlets compile the bundled runtime and examples themselves, so every build checks they still do.
let checkRuntime: TargetScript = .pre(script: """
    set -euo pipefail
    xcrun swiftc -typecheck -parse-as-library -swift-version 5 -module-cache-path "$DERIVED_FILE_DIR/RuntimeCheckCache" \\
        "$SRCROOT/Sources/NoodleApplet/Resources/WindowFocusGuard.swift" \\
        "$SRCROOT/Sources/NoodleApplet/Resources/NoodletRuntime.swift" \\
        "$SRCROOT/Sources/NoodleApplet/Resources/Examples/Orbit.noodlet/Orbit.swift"
    """, name: "Check Noodlet Runtime", basedOnDependencyAnalysis: false)

/// The app already has outbound network access, so Sparkle's separate downloader goes. Removing it
/// changes the framework, so it is signed again, inside out.
let trimSparkle: TargetScript = .post(script: """
    set -euo pipefail
    sparkle="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/Sparkle.framework"
    rm -rf "$sparkle/Versions/B/XPCServices/Downloader.xpc"
    for component in "$sparkle/Versions/B/XPCServices/Installer.xpc" "$sparkle/Versions/B/Autoupdate" \\
                     "$sparkle/Versions/B/Updater.app" "$sparkle"; do
        codesign --force --options runtime "$APPLET_CODESIGN_TIMESTAMP" --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$component"
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
    name: "NoodleApplet",
    packages: [
        .local(path: "."),
        .local(path: "Protocol"),
        .local(path: "../Shared/SettingsUI"),
        .local(path: "../Shared/LaunchChecks"),
        .local(path: "../Shared/Wallpaper"),
        .remote(url: "https://github.com/sparkle-project/Sparkle", requirement: .exact("2.9.4")),
    ],
    settings: .settings(
        base: [
            "DEVELOPMENT_TEAM": "S8VNVK39LH",
            "MACOSX_DEPLOYMENT_TARGET": "15.0",
            // Releases ship for Apple silicon only.
            "ARCHS": "arm64",
            "SWIFT_VERSION": "5",
            "MARKETING_VERSION": .string(version),
            "CURRENT_PROJECT_VERSION": .string(version),
            // The helper phases sign without a timestamp; public releases pass APPLET_CODESIGN_TIMESTAMP=--timestamp.
            "APPLET_CODESIGN_TIMESTAMP": "--timestamp=none",
        ],
        configurations: [
            .debug(name: "Debug", settings: [
                "APPLET_APP_BUNDLE_ID": "com.pdparchitect.noodle.applet.local",
                "APPLET_APP_NAME": "Noodle Applet Dev",
                "APPLET_GROUP_SUFFIX": "com.pdparchitect.noodle.applets.local",
                "APPLET_DOCUMENT_EXTENSION": "noodlet-dev",
                "APPLET_DOCUMENT_TYPE_NAME": "Noodlet Dev",
            ]),
            .release(name: "Release", settings: [
                "APPLET_APP_BUNDLE_ID": "com.pdparchitect.noodle.applet",
                "APPLET_APP_NAME": "Noodle Applet",
                "APPLET_GROUP_SUFFIX": "com.pdparchitect.noodle.applets",
                "APPLET_DOCUMENT_EXTENSION": "noodlet",
                "APPLET_DOCUMENT_TYPE_NAME": "Noodlet",
                // Signing adds get-task-allow for the debugger; a release carries only its own entitlements.
                "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO",
            ]),
        ]
    ),
    targets: [
        .target(
            name: "NoodleApplet",
            destinations: .macOS,
            product: .app,
            productName: "NoodleApplet",
            bundleId: "com.pdparchitect.noodle.applet",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .file(path: "Support/Info.plist"),
            // The Resources folder holds the noodlet runtimes and examples; its Swift files are
            // compiled by noodlets later, not by the app.
            sources: .sourceFilesList(globs: [
                .glob("Sources/NoodleApplet/**", excluding: ["Sources/NoodleApplet/Resources/**"]),
            ]),
            resources: [
                .folderReference(path: "Sources/NoodleApplet/Resources"),
                "Support/Assets.xcassets",
                "Support/AppSymbol.svg",
            ],
            entitlements: .file(path: "Support/Applet.entitlements"),
            scripts: [checkRuntime, embedHelpers, trimSparkle],
            dependencies: [
                .package(product: "AppletCore"),
                .package(product: "AppletBridge"),
                .package(product: "NoodleSettingsUI"),
                .package(product: "NoodleLaunchChecks"),
                .package(product: "NoodleWallpaper"),
                .package(product: "Sparkle"),
                .target(name: "NoodletHost"),
                .target(name: "NoodletPreview"),
                .target(name: "noodlet"),
            ],
            settings: .settings(
                base: signing.merging([
                    "PRODUCT_BUNDLE_IDENTIFIER": "$(APPLET_APP_BUNDLE_ID)",
                    "PRODUCT_NAME": "$(APPLET_APP_NAME)",
                    "EXECUTABLE_NAME": "NoodleApplet",
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppletIcon",
                    // Embed Helpers writes into the app bundle.
                    "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
                    // Updates stay off unless a public release passes
                    // INFOPLIST_PREPROCESSOR_DEFINITIONS=APPLET_UPDATES_ENABLED=true.
                    "INFOPLIST_PREPROCESS": "YES",
                    "INFOPLIST_PREPROCESSOR_DEFINITIONS": "APPLET_UPDATES_ENABLED=false",
                    // Traditional mode keeps the "//" in URLs instead of reading it as a comment.
                    "INFOPLIST_OTHER_PREPROCESSOR_FLAGS": "-traditional",
                ]) { $1 },
                configurations: [
                    .debug(name: "Debug", settings: ["SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) DEBUG NOODLE_DEV_HOOKS"]),
                    .release(name: "Release"),
                ]
            )
        ),
        // Runs native noodlets outside the app's sandbox, confined to their own files. It accepts Applet alone.
        .target(
            name: "NoodletHost",
            destinations: .macOS,
            product: .xpc,
            bundleId: "com.pdparchitect.noodle.applet.noodlet-host",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleName": "Noodlet Host",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "LSBackgroundOnly": true,
                "XPCService": ["ServiceType": "Application", "JoinExistingSession": true],
                "NoodleAppletIdentifier": "$(APPLET_APP_BUNDLE_ID)",
                "NoodleSigningTeam": "$(DEVELOPMENT_TEAM)",
            ]),
            sources: ["Sources/NoodletHost/**"],
            dependencies: [.package(product: "AppletCore")],
            settings: .settings(base: signing.merging([
                "PRODUCT_BUNDLE_IDENTIFIER": "$(APPLET_APP_BUNDLE_ID).noodlet-host",
                "PRODUCT_NAME": "NoodletHost",
            ]) { $1 })
        ),
        // Quick Look previews of noodlet documents, sandboxed and sharing Applet's group.
        .target(
            name: "NoodletPreview",
            destinations: .macOS,
            product: .appExtension,
            bundleId: "com.pdparchitect.noodle.applet.preview",
            deploymentTargets: .macOS("15.0"),
            infoPlist: .file(path: "Support/Preview-Info.plist"),
            sources: ["Sources/NoodletPreview/**"],
            entitlements: .file(path: "Support/Preview.entitlements"),
            dependencies: [.package(product: "AppletCore"), .package(product: "AppletBridge")],
            settings: .settings(base: signing.merging([
                "PRODUCT_BUNDLE_IDENTIFIER": "$(APPLET_APP_BUNDLE_ID).preview",
                "PRODUCT_NAME": "NoodletPreview",
            ]) { $1 })
        ),
        // The noodlet command. The app signs it when it embeds it; see embedHelpers.
        .target(
            name: "noodlet",
            destinations: .macOS,
            product: .commandLineTool,
            bundleId: "noodlet",
            deploymentTargets: .macOS("15.0"),
            sources: ["Sources/NoodletCLI/**"],
            dependencies: [.package(product: "AppletCore"), .package(product: "AppletBridge")],
            // main.swift declares @main, which SwiftPM compiles as a library file; Xcode must be told.
            settings: .settings(base: ["PRODUCT_BUNDLE_IDENTIFIER": "noodlet", "CODE_SIGNING_ALLOWED": "NO",
                                       "OTHER_SWIFT_FLAGS": "$(inherited) -parse-as-library"])
        ),
    ]
)
