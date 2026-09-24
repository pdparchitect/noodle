# Noodle Browser

This is an independently versioned companion app. Keep its user-visible changes
in `CHANGELOG.md`, its version in `VERSION`, and Noodle-side integration changes
in the repository changelog. Do not publish a release without an explicit request.

Use public WebKit APIs. Browser UUIDs identify persistent website data stores;
never replace an existing UUID when reopening a profile. Save tab and download
metadata separately. History and bookmarks use the per-profile records database;
keep queries paginated and resolve bookmark IDs only within the selected profile.
Background automation must not activate windows or post
input to the system event stream. New/restored tabs and popups inherit the
profile's mute setting before navigation.

Keep assignment authorization in Noodle. Only the signed Noodle broker or its
bundled Browser tool extension may use the companion socket and choose shared
transfer IDs; the extension only forwards calls the broker already authorized. Agent file paths must pass
through the workspace file-transfer boundary, not the browser's filesystem.
Protocol changes need coordinated broker/CLI handling and generated guidance in
`Sources/NoodleCore/MessengerDocumentation.swift`.

Run the unit tests and signed fake-site fixture for changes to WebKit operations,
persistence or transfers. Fixtures use separate UUIDs and `.accessory` activation;
never test against the user's ordinary browser profiles or credentials. Verify
actual entitlements with `scripts/verify-browser-release.sh`.

The app is built from an Xcode project that Tuist generates from `Project.swift`; the generated
project and `Derived/` are not committed. Describe targets, settings and embedding there, never by
editing the generated project. Its build phases embed the page scripts and trim Sparkle; everything
else is target settings.

README.md is for people using Browser; do not document code in it. Follow the
`no-code-docs` skill.
