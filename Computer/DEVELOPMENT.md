# Build and test Computer

Run commands from the repository root. You need Apple silicon, macOS 26, Xcode 26,
Go 1.26 or later, and Git LFS. Go builds the file helper that runs inside guests.

```sh
git lfs pull
zsh scripts/build-and-launch-computer.sh
```

The kernel is tracked with Git LFS; its provenance is in
[the kernel notice](Support/KERNEL-NOTICE.txt). Builds use release optimization.
Set `NOODLE_COMPUTER_CONFIGURATION=debug` for debugging.

The build is packaged at `.build/Noodle Computer Dev.app`; the launcher installs
it as `/Applications/Noodle Computer Dev.app`. Local Mac accounts must be able
to read the desktop helper, so a private source folder is not a runnable install
location for that backend. The launcher leaves the build path as a symlink to the
installed app so existing development service registrations can resolve it.
Existing Local app paths are preserved as compatibility aliases during migration.
Once service registration uses the Dev installation, obsolete aliases can be retired;
subsequent installs will not recreate them. Internal IDs and existing account data
locations stay unchanged.

Installation validates the development identity and signatures, publishes atomically,
and never replaces `/Applications/Noodle Computer.app`. It pairs exclusively
with `.build/Noodle Dev.app`, using its own sandbox container, computer library,
App Group connection, Local Mac service, account records and credentials. The
installed production apps continue to use each other. Both pairs can run at once.
Existing production computers are not copied or adopted by the Dev build.
Local Mac requires its own initial helper approval and new managed accounts.
Development references use `.noodlecomputer-dev`; production uses `.noodlecomputer`.
The app and both Quick Look extensions register only their own document type.

Build Noodle Dev with `scripts/build-and-launch.sh`. It finds Computer Dev
beside its own bundle or by its registered development identity. It never falls back to
the production app. Both launch scripts force development identities, verify the
resulting bundle ID, and reject arguments; shell environment overrides cannot
make them launch production. Runbar uses these scripts and has no production-data
launcher.

Release packaging explicitly sets `NOODLE_COMPUTER_DATA_CONTAINER=production`.
This is a packaging option, not a development launch mode. The isolated test
bundle has a third connection group and cannot register Local Mac services.

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
'.build/Noodle Dev.app/Contents/MacOS/Noodle' --computer-document-preview-test
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
