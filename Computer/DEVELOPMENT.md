# Build and test Computer

Run commands from the repository root. You need Apple silicon, macOS 26, Xcode 26,
Go 1.26 or later, and Git LFS. Go builds the file helper that runs inside guests.

```sh
git lfs pull
zsh scripts/build-computer.sh
open '.build/Noodle Computer.app'
```

The kernel is tracked with Git LFS; its provenance is in
[the kernel notice](Support/KERNEL-NOTICE.txt). Builds use release optimization.
Set `NOODLE_COMPUTER_CONFIGURATION=debug` for debugging.

Noodle Local opens attachments with the running Computer app. When Computer is
closed, it prefers `Noodle Computer.app` beside its own bundle, before the release
registered with macOS. Launch the intended Computer build before testing if both
development and release copies are installed; only one process can own a library.

## Tests

```sh
swift test --disable-sandbox --package-path Computer --scratch-path .build/computer
swift test --disable-sandbox --package-path Computer/Bridge
swift test --disable-sandbox --package-path Computer/Presentation
```

Computer's preview and thumbnail extensions are bundled and signed by the same
build script. Each has only App Sandbox, without network, App Group or optional
file access entitlements. `verify-computer-release.sh` checks both installed
extension signatures, document-type declarations and their exact entitlement set.
Quick Look renders the saved content; opening a document selects and starts its
computer in the main library window. Document tests cover saved content and
reference compatibility; Computer storage tests cover reference selection without
launching guests or accessing real libraries. The separate live viewer has been
removed. Only [notes from the Quick Look investigation](Prototypes/QuickLook/README.md)
are retained from the temporary prototype.

To verify a registered extension through the modern macOS thumbnail API:

```sh
swiftc -parse-as-library Computer/Tests/NativeThumbnailProbe.swift -o /tmp/computer-thumbnail-probe
/tmp/computer-thumbnail-probe /path/to/reference.noodlecomputer /tmp/computer-thumbnail.png
```

This bounded check reads only the supplied reference and writes the requested
image. It does not start a computer. The Computer app must already be registered
with Launch Services and its thumbnail extension enabled. `qlmanage -t` timed out
on the development machine while the modern API rendered the extension correctly.

To exercise Noodle's real Quick Look panel after building both apps:

```sh
'.build/Noodle Local.app/Contents/MacOS/Noodle' --computer-document-preview-test
```

This opt-in fixture runs before Noodle opens its workspace. It generates temporary
computer, text and unknown-type files, repeats preview selection and closing,
and prints a screenshot path for visual verification. It does not load agents or
start guests. Document tests also verify that preparing a preview preserves the
root view exported through macOS ViewBridge.

Desktop startup preserves its readiness retries while macOS's first Local Network
permission prompt is open. If startup still fails, a bounded Network.framework
connection to the same guest endpoint checks specifically for `localNetworkDenied`.
That failure shows Open Settings and Try Again; an ordinary offline or unreachable
endpoint keeps its original error. `LocalNetworkAccessTests` cover denial, timeout,
cancellation, and recovery state with an injected connection, without changing
privacy settings. Terminal-launched tests cannot validate the app's Local Network
grant; check that manually with the signed app when permission changes are allowed.

To check shell selection, history, editing, completion, and interrupt keys in
real Linux PTYs, pass locally available image names to the shell test:

```sh
python3 Computer/Tests/GuestShellTests.py noodle-computer-shell-image:local noodle-computer-desktop-image:local
```

This check uses Apple's `container` CLI and disposable containers with networking
disabled and no host mounts. See [image builds](Images/README.md#build-and-test).

For signed integration fixtures, build a separate test app:

```sh
NOODLE_COMPUTER_TEST_BUILD=1 zsh scripts/build-computer.sh
'.build/Noodle Computer Tests.app/Contents/MacOS/NoodleComputer' --self-test
```

Fixtures use temporary libraries. Some download images and start real guests.
Run only the checks relevant to your change:

| Flag | Checks |
| --- | --- |
| `--self-test` | Container boot, networking, guest commands, and disk persistence |
| `--self-test --offline` | Guest execution without guest networking; initial downloads still need the host network |
| `--desktop-smoke-test` | Desktop startup, authenticated display, and recovery terminal |
| `--custom-container-test` | Custom web image and shell-only image |
| `--files-test` | File browsing and transfers; add `--keep-test-window` for manual checks |
| `--overlay-test` | Persistent writes, image replacement, and update recovery |
| `--latest-images-test` | Public preset downloads, startup, and image updates |
| `--creation-form-test` | Creation form, layout, and controls |

Failed desktop/latest-image tests retain their fixtures for diagnosis. Passing
runs clean up. See [bridge tests](Bridge/README.md#tests) for Noodle integration
and [release checks](RELEASING.md#local-checks) for packaging.

## Source map

- `ComputerCore`: records, storage, and validation.
- `NoodleComputer`: views, runtime, terminal, and file browser.
- `Bridge`: protocol shared with Noodle.
- `Images`: Shell and Desktop image definitions.
- `Shared/Wallpaper` at the repository root: background imports and playback used by both apps.

Add templates in [`container-registry.json`](Sources/ComputerCore/Resources/container-registry.json).
Use a unique ID, an image reference, and an existing `desktop` or `shell` runtime
type. Desktop images must support the [desktop service contract](Images/README.md#desktop-startup-contract-v1). New runtime types
need code as well as a registry entry.

The source retains macOS and installer-based Linux VM support, but these are not
options in the creation dialog. A full macOS installation and Omarchy desktop
remain unverified.

[Computer](README.md)
