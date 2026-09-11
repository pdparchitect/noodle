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

## Tests

```sh
swift test --disable-sandbox --package-path Computer --scratch-path .build/computer
swift test --disable-sandbox --package-path Computer/Bridge
```

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
type. Desktop images must support the desktop service contract. New runtime types
need code as well as a registry entry.

The source retains macOS and installer-based Linux VM support, but these are not
options in the creation dialog. A full macOS installation and Omarchy desktop
remain unverified.

[Computer](README.md)
