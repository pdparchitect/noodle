# Releases and updates

Commands and project paths below are relative to the repository root.

The root `VERSION` file is the canonical stable application version (`X.Y.Z`). Swift Package Manager describes the package and deployment target, but it does not provide a macOS app marketing version. Starting with the updater bootstrap, the build copies `VERSION` into both `CFBundleShortVersionString` and `CFBundleVersion`, so local builds and CI releases use the same ordering. Increase it for every release; never reuse a published version. `SUPERBOT_BUILD_NUMBER` is a local-testing override only; release packaging always uses `VERSION`.

To publish a release, update `VERSION`, commit the change, and run:

```sh
scripts/create-release-tag.sh
```

The script creates and pushes a matching `vX.Y.Z` tag. GitHub Actions runs the tests, imports the dedicated Developer ID Application identity into an ephemeral keychain, signs the app and every embedded executable, submits the archive to Apple's notary service, staples the ticket, and verifies Gatekeeper acceptance. Sparkle then signs the final ZIP and generates a signed `appcast.xml`. The release stays a draft until its ZIP, checksum, and appcast have all uploaded, then becomes the latest GitHub release.

The release workflow reads signing material only from encrypted GitHub Actions secrets:

- `MACOS_CERTIFICATE_P12`
- `MACOS_CERTIFICATE_PASSWORD`
- `APP_STORE_CONNECT_API_KEY_P8`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `SPARKLE_PRIVATE_KEY`

The `.p12` secret is used only for code signing; the App Store Connect API key is used only for notarization. The dedicated Sparkle Ed25519 private key signs update archives and feeds; only its public key is embedded in the app. No certificate, private key, password, or notarization credential belongs in the repository. Temporary CI signing material is removed on success or failure.

### In-app updates

Use **SuperBot → Check for Updates…** or **Settings → Updates**. Automatic daily checks are enabled by default. Automatic download/installation is a separate opt-in setting. Sparkle provides release prompts, progress, signature validation, installation, and relaunch. Restarting is postponed while an agent is starting/working, a message or attachment is unsent, an editor is open, or a shared item is being delivered. An additional termination check protects a resumed installation as well.

The app fetches `https://github.com/pdparchitect/superbot/releases/latest/download/appcast.xml`; its enclosures point to versioned ZIP assets in the same GitHub repository. There is no separate server, GitHub Pages site, access token in the app, or custom download service. Only publish stable releases as “latest.” The previous release remains available while CI builds and uploads the next one.

Sparkle is pinned to 2.9.4 in `Package.swift` and `Package.resolved`, from [sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle). Its complete upstream licence is copied into the signed app's Resources. To regenerate a feed locally without exporting the dedicated Keychain key, use the bundled `generate_appcast --account com.pdparchitect.superbot` tool. Back up the signing key securely: losing it prevents straightforward updates for existing installations. Never rotate the embedded public key without following Sparkle's key-transition procedure.

Release assets must be accessible to the app for update checks and downloads to work. While the repository is private, the unauthenticated updater cannot fetch those assets; the app does not embed a GitHub access token.


---

[Documentation](README.md) · [SuperBot](../README.md)

