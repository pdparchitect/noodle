import Foundation
import ProjectDescription

// Noodle Computer as an Xcode project. The code stays in Swift packages; this describes the app bundle
// they are assembled into. Debug is Noodle Computer Dev, Release is Noodle Computer and Tests is the
// isolated Noodle Computer Tests that the signed integration fixtures run in.
let version = (try? String(contentsOfFile: "VERSION", encoding: .utf8))?
    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0.0.0"

/// Every signed target uses the same identity, hardened.
let signing: SettingsDictionary = [
    "CODE_SIGN_STYLE": "Automatic",
    "CODE_SIGN_IDENTITY": "Apple Development",
    "ENABLE_HARDENED_RUNTIME": "YES",
]

/// The virtual machines boot the pinned kernel, so a build refuses any other.
let checkKernel: TargetScript = .pre(script: """
    set -euo pipefail
    kernel="$SRCROOT/Resources/Runtime/vmlinux-arm64"
    if [ ! -f "$kernel" ] || [ "$(stat -f %z "$kernel")" -lt 1000000 ]; then
        echo "error: Missing runtime kernel. See Computer/README.md (git lfs pull)." >&2; exit 1
    fi
    [ "$(shasum -a 256 "$kernel" | awk '{print $1}')" = fb2cfb79eb1ae19447a85d75682d7fa5cfec97e24beb2609a492b806e8072c8d ] || {
        echo "error: The runtime kernel does not match its pinned checksum." >&2; exit 1
    }
    """, name: "Check Kernel", basedOnDependencyAnalysis: false)

/// A static Linux helper runs inside the guest, never as a host executable. Xcode's script PATH
/// leaves out the usual Go installs.
let buildGuestFiles: TargetScript = .post(script: """
    set -euo pipefail
    export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/local/go/bin"
    command -v go >/dev/null || { echo "error: Building Computer requires Go for its Linux guest file helper." >&2; exit 1; }
    export GOCACHE="$DERIVED_FILE_DIR/GoCache"
    CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -ldflags='-s -w' \\
        -o "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Runtime/noodle-files" "$SRCROOT/GuestFiles/main.go"
    """, name: "Build Guest Files", basedOnDependencyAnalysis: false)

/// Local Mac is registered only when the user enables it. The app keeps its sandbox; a setup app
/// carrying the account service and its daemon, and a desktop app, sit in Contents/Helpers. They are
/// built unsigned and signed here, inside out, so none of them gains an entitlement it does not
/// declare. macOS shows a helper's localized name only when its base name matches the bundle's
/// file name, so the build-specific names go in InfoPlist.strings.
let embedHelpers: TargetScript = .post(script: """
    set -euo pipefail
    helpers="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
    rm -rf "$helpers"
    mkdir -p "$helpers"
    sign() { codesign --force --options runtime "$COMPUTER_CODESIGN_TIMESTAMP" --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$@"; }
    group="$DEVELOPMENT_TEAM.$COMPUTER_GROUP_SUFFIX"

    setup="$helpers/LocalMacSetup.app"
    ditto "$BUILT_PRODUCTS_DIR/LocalMacSetup.app" "$setup"
    mkdir -p "$setup/Contents/Library/LaunchServices" "$setup/Contents/Library/LaunchDaemons" "$setup/Contents/Resources/en.lproj"
    ditto "$BUILT_PRODUCTS_DIR/LocalMacService" "$setup/Contents/Library/LaunchServices/LocalMacService"
    printf '"CFBundleName" = "%s Setup";\\n"CFBundleDisplayName" = "%s Setup";\\n' "$PRODUCT_NAME" "$PRODUCT_NAME" \\
        > "$setup/Contents/Resources/en.lproj/InfoPlist.strings"
    daemon="$setup/Contents/Library/LaunchDaemons/$PRODUCT_BUNDLE_IDENTIFIER.localmac.plist"
    /usr/libexec/PlistBuddy -c "Add :Label string $group.localmac" \\
        -c 'Add :BundleProgram string Contents/Library/LaunchServices/LocalMacService' \\
        -c 'Add :MachServices dict' -c "Add :MachServices:$group.localmac bool true" \\
        -c 'Add :AssociatedBundleIdentifiers array' -c "Add :AssociatedBundleIdentifiers:0 string $PRODUCT_BUNDLE_IDENTIFIER" \\
        -c 'Add :ProcessType string Interactive' "$daemon" >/dev/null
    sign --identifier "$PRODUCT_BUNDLE_IDENTIFIER.localmac" "$setup/Contents/Library/LaunchServices/LocalMacService"
    sign "$setup"

    desktop="$helpers/LocalMacDesktop.app"
    ditto "$BUILT_PRODUCTS_DIR/LocalMacDesktop.app" "$desktop"
    mkdir -p "$desktop/Contents/Resources/en.lproj"
    printf '"CFBundleName" = "%s";\\n"CFBundleDisplayName" = "%s";\\n' "$COMPUTER_DESKTOP_NAME" "$COMPUTER_DESKTOP_NAME" \\
        > "$desktop/Contents/Resources/en.lproj/InfoPlist.strings"
    # The desktop helper owns its terminal children's Automation consent; each app still needs approval.
    sign --entitlements "$SRCROOT/Support/LocalMacDesktop.entitlements" "$desktop"
    """, name: "Embed Helpers", basedOnDependencyAnalysis: false)

/// The app already has outbound network access, so Sparkle's separate downloader goes. Removing it
/// changes the framework, so it is signed again, inside out. Every dependency's licence ships too.
let trimSparkle: TargetScript = .post(script: """
    set -euo pipefail
    sparkle="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH/Sparkle.framework"
    rm -rf "$sparkle/Versions/B/XPCServices/Downloader.xpc"
    for component in "$sparkle/Versions/B/XPCServices/Installer.xpc" "$sparkle/Versions/B/Autoupdate" \\
                     "$sparkle/Versions/B/Updater.app" "$sparkle"; do
        codesign --force --options runtime "$COMPUTER_CODESIGN_TIMESTAMP" --sign "$EXPANDED_CODE_SIGN_IDENTITY" "$component"
    done
    # Package checkouts sit beside Build/ in derived data, which archives nest deeper.
    packages="$BUILD_DIR"
    while [ ! -d "$packages/SourcePackages" ]; do
        [ "$packages" != / ] || { echo "error: no Swift package checkouts above $BUILD_DIR" >&2; exit 1; }
        packages="$(dirname "$packages")"
    done
    for dependency in "$packages/SourcePackages/checkouts"/*; do
        for license in LICENSE LICENSE.txt COPYING; do
            [ -f "$dependency/$license" ] && cp -f "$dependency/$license" \\
                "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/$(basename "$dependency")-$license.txt"
        done
    done
    """, name: "Trim Sparkle", basedOnDependencyAnalysis: false)

/// A Local Mac helper, built unsigned; embedHelpers signs it where it ships.
func localMac(_ name: String, product: Product, infoPlist: InfoPlist? = nil, resources: ResourceFileElements? = nil) -> Target {
    .target(
        name: name,
        destinations: .macOS,
        product: product,
        bundleId: name,
        deploymentTargets: .macOS("26.0"),
        infoPlist: infoPlist,
        sources: ["LocalMac/Sources/\(name)/**"],
        resources: resources,
        dependencies: [.package(product: "LocalMacCore")],
        settings: .settings(base: [
            "CODE_SIGNING_ALLOWED": "NO",
            "PRODUCT_NAME": .string(name),
            "PRODUCT_BUNDLE_IDENTIFIER": .string(product == .app ? "$(COMPUTER_APP_BUNDLE_ID).\(name == "LocalMacSetup" ? "localmacsetup" : "desktop")" : name),
        ])
    )
}

let project = Project(
    name: "NoodleComputer",
    packages: [
        .local(path: "."),
        .local(path: "Bridge"),
        .local(path: "LocalMac"),
        .local(path: "../Shared/SettingsUI"),
        .local(path: "../Shared/LaunchChecks"),
        .local(path: "../Shared/Wallpaper"),
        .remote(url: "https://github.com/sparkle-project/Sparkle", requirement: .exact("2.9.4")),
        .remote(url: "https://github.com/apple/containerization.git", requirement: .exact("0.43.0")),
        .remote(url: "https://github.com/migueldeicaza/SwiftTerm.git", requirement: .exact("1.20.0")),
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
            // The helper phases sign without a timestamp; public releases pass COMPUTER_CODESIGN_TIMESTAMP=--timestamp.
            "COMPUTER_CODESIGN_TIMESTAMP": "--timestamp=none",
            "COMPUTER_DESKTOP_NAME": "Noodle Local Mac Desktop",
        ],
        configurations: [
            .debug(name: "Debug", settings: [
                "COMPUTER_APP_BUNDLE_ID": "com.pdparchitect.noodle.computer.local",
                "COMPUTER_APP_NAME": "Noodle Computer Dev",
                "COMPUTER_GROUP_SUFFIX": "com.pdparchitect.noodle.computers.local",
                "COMPUTER_DOCUMENT_SUFFIX": "-dev",
                "COMPUTER_DESKTOP_NAME": "Noodle Local Mac Desktop Dev",
            ]),
            .release(name: "Release", settings: [
                "COMPUTER_APP_BUNDLE_ID": "com.pdparchitect.noodle.computer",
                "COMPUTER_APP_NAME": "Noodle Computer",
                "COMPUTER_GROUP_SUFFIX": "com.pdparchitect.noodle.computers",
                "COMPUTER_DOCUMENT_SUFFIX": "",
                // Signing adds get-task-allow for the debugger; a release carries only its own entitlements.
                "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO",
            ]),
            .release(name: "Tests", settings: [
                "COMPUTER_APP_BUNDLE_ID": "com.pdparchitect.noodle.computer.tests",
                "COMPUTER_APP_NAME": "Noodle Computer Tests",
                "COMPUTER_GROUP_SUFFIX": "com.pdparchitect.noodle.computers.tests",
                "COMPUTER_DOCUMENT_SUFFIX": "-tests",
                "CODE_SIGN_INJECT_BASE_ENTITLEMENTS": "NO",
            ]),
        ]
    ),
    targets: [
        .target(
            name: "NoodleComputer",
            destinations: .macOS,
            product: .app,
            productName: "NoodleComputer",
            bundleId: "com.pdparchitect.noodle.computer",
            deploymentTargets: .macOS("26.0"),
            infoPlist: .file(path: "Support/Info.plist"),
            sources: ["Sources/NoodleComputer/**"],
            resources: [
                .folderReference(path: "Resources/Runtime"),
                "Support/Assets.xcassets",
                "Support/AppSymbol.svg",
                "Support/KERNEL-NOTICE.txt",
                "Support/STUDIO-NOTICE.txt",
            ],
            entitlements: .file(path: "Support/Computer.entitlements"),
            scripts: [checkKernel, buildGuestFiles, embedHelpers, trimSparkle],
            dependencies: [
                .package(product: "ComputerCore"),
                .package(product: "NoodleLaunchChecks"),
                .package(product: "NoodleSettingsUI"),
                .package(product: "NoodleWallpaper"),
                .package(product: "Sparkle"),
                .package(product: "ComputerBridge"),
                .package(product: "LocalMacCore"),
                .package(product: "SwiftTerm"),
                .package(product: "Containerization"),
                .package(product: "ContainerizationEXT4"),
                .package(product: "ContainerizationExtras"),
                .package(product: "ContainerizationOCI"),
                .target(name: "LocalMacSetup"),
                .target(name: "LocalMacService"),
                .target(name: "LocalMacDesktop"),
            ],
            settings: .settings(
                base: signing.merging([
                    "PRODUCT_BUNDLE_IDENTIFIER": "$(COMPUTER_APP_BUNDLE_ID)",
                    "PRODUCT_NAME": "$(COMPUTER_APP_NAME)",
                    "EXECUTABLE_NAME": "NoodleComputer",
                    "ASSETCATALOG_COMPILER_APPICON_NAME": "Computer",
                    // The script phases write into the app bundle.
                    "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
                    // Updates stay off unless a public release, or an updater check on the Tests app, passes
                    // INFOPLIST_PREPROCESSOR_DEFINITIONS=COMPUTER_UPDATES_ENABLED=true.
                    "INFOPLIST_PREPROCESS": "YES",
                    "INFOPLIST_PREPROCESSOR_DEFINITIONS": "COMPUTER_UPDATES_ENABLED=false",
                    // Traditional mode keeps the "//" in URLs instead of reading it as a comment.
                    "INFOPLIST_OTHER_PREPROCESSOR_FLAGS": "-traditional",
                ]) { $1 },
                configurations: [
                    .debug(name: "Debug", settings: ["SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) DEBUG NOODLE_DEV_HOOKS"]),
                    .release(name: "Release"),
                    .release(name: "Tests", settings: ["SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) NOODLE_DEV_HOOKS"]),
                ]
            )
        ),
        localMac("LocalMacSetup", product: .app, infoPlist: .file(path: "Support/LocalMacSetup-Info.plist")),
        localMac("LocalMacDesktop", product: .app, infoPlist: .file(path: "Support/LocalMacDesktop-Info.plist"),
                 resources: ["Images/shared/noodle-welcome"]),
        localMac("LocalMacService", product: .commandLineTool),
    ]
)
