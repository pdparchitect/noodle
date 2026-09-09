# Noodle Computer

Standalone, sandboxed macOS app in the Noodle source repository. Requires an
Apple silicon Mac, macOS 26, and Xcode 26. It has a separate Swift package and
build directory: Noodle's existing deployment target, dependencies, entitlements,
binary and user data do not change.

## Build and run

Run `zsh scripts/build-computer.sh` from the repository root, then
`open ".build/Noodle Computer.app"`.
The official bundle uses an optimized release build; set
`NOODLE_COMPUTER_CONFIGURATION=debug` only when debugging source.

The runtime kernel is tracked with Git LFS. Run `git lfs pull` if the build reports
a missing kernel. Its provenance is recorded in `Support/KERNEL-NOTICE.txt`.

## v1 scope

The standard creation dialog offers exactly two container templates. No Docker Desktop installation
is required: Docker/OCI images run using the embedded Apple Containerization runtime.

- **Desktop:** the digest-pinned Launcher desktop with browser, terminal and file
  manager. Defaults to 4 CPUs, 4 GB memory and a sparse 32 GB disk. Networking is
  required for the embedded desktop viewer.
- **Shell:** Alpine Linux 3.23.5 with a native interactive terminal. Defaults to
  2 CPUs, 1 GB memory and a sparse 4 GB disk. Networking can be disabled.

Both choose their images automatically and keep resource controls under Advanced
Options. Existing Alpine workspaces appear as Shell; existing Launcher workspaces
appear as Desktop. Their records and disks are unchanged. Unknown custom container
images retain their generic type instead of being relabelled as a known template.

The next stage is exposing these computers to Noodle agents. This stage does not
ship an agent-facing tool, file-transfer interface or connection protocol. Guest
execution and lifecycle control remain behind the central store/runtime boundary.
Computer stays out of the release changelog until it is ready.

### Custom container images

**New from Container Image…** is a separate create-menu action. Enter a public
ARM64 OCI image reference. A blank web port uses the image as a Shell-style
workspace; it does not start the image's application command. With a web port,
the image's entrypoint and command run with its configured environment, user and
working directory, and the app displays `http://<guest-address>:<port>/`.
The image must include `/bin/sh`; the web service must listen on the guest network
interface, not only localhost. Registry credentials and Compose are not supported.
The application process runs alongside the workspace keeper, not as PID 1.

Custom web views are confined to that guest origin, use an ephemeral WebKit store,
and offer Try Again when the application has not become ready yet. They do not
publish a host port. Local-network HTTP is allowed for these explicitly selected
guest services; the built-in Desktop still uses authenticated, pinned HTTPS.

### Appearance

Create and Edit both offer Noodle-style icon customisation (symbol, gradient colour
or imported image) and window wallpaper (Default, Sunset, Ocean, Forest, Dusk or an
imported image). Wallpaper extends behind both columns. Terminal and web display
have a 12-point outside margin, below the native toolbar.
Terminal text colour, background colour and background opacity are independent.
Transparency affects the default background, not text or explicitly coloured cells.
Choices are saved with each computer. Image imports are user-selected, decoded and
downsampled before storage; no permanent access to the source file is retained.

## Retained VM foundations (not offered in v1 creation)

The runtime and storage formats below remain intact for existing computers and
future VM templates. They are not selectable in the v1 New Computer dialog.

- **macOS:** the backend accepts an Apple IPSW or downloads the latest compatible
  restore image. Installation uses its own sparse virtual disk. Initial Apple
  setup takes place in the computer's desktop. This can download several GB.
  Creation replaces the setup form with a progress dialog: transferred bytes,
  percentage and average speed during downloads, Apple's installation progress,
  elapsed time, and Cancel. Cancellation waits for the installer to stop
  before cleaning up the unpublished computer. Completed downloads are retained
  in the private runtime cache; the current Apple restore URL, recorded file size
  and SHA-256 must match before reuse. Partial or damaged downloads are not reused.
- **Linux:** automatically downloads the pinned Alpine 3.23.5 ARM64 installer,
  verifies its published SHA-256, and caches it for reuse. The backend also accepts
  a custom ARM64 UEFI ISO. Existing installer-backed computers can still install
  onto their private virtual disk. Shut down, then choose **Installation Finished — Eject
  ISO** before the next boot. Full desktop and keyboard/pointer input use Apple's
  `VZVirtualMachineView`.
- **Omarchy:** experimental Linux runtime for a prepared ARM64 installer.
  Stock x86-64 ISOs cannot be hardware-virtualized on Apple silicon. A boot-tested
  Omarchy ARM64 image and Hyprland compatibility are not yet provided.

## Container display

A digest-pinned Launcher desktop image (Ubuntu, Openbox,
  Chromium, terminal and file manager), running through embedded Containerization
  and Apple vminit 0.43.0. The app displays the live KasmVNC screen using a private
  WebKit store, a per-start password and a guest certificate pinned via the
  virtualization control channel. No host port is published; no public host
  listener is created. The unauthenticated guest preview API is disabled.
  Existing Alpine workspaces are retained as headless computers; their disks are
  not replaced or converted. Headless workspaces open an interactive native
  terminal connected to a guest PTY, with keyboard input, resize and Control-C.
  There is no Run dialog or startup-log screen. SwiftTerm is pinned and linked
  into the sandboxed app; it never launches a host shell. Guest clipboard escape
  sequences and host link-opening requests are denied.

Desktop also has a **Show Terminal / Show Desktop** toolbar switch. Its recovery
shell opens on demand through a separate guest PTY and remains alive when hidden.
The desktop connection is retained when switching. This works independently of
the guest desktop/display server; it cannot recover an unresponsive whole VM.

## Studio baseline

The container implementation uses Studio's embedded Apple Containerization
approach: `LinuxPod`, `VZVirtualMachineManager`, the same kernel and vminit image,
journaled ext4, and NAT with bounded guest DHCP. It does not include Studio's
web application/Compose stack, host port forwarders, credentials or microphone.
Each workspace has its own VM and rootfs; images/initfs are cached centrally.
A separate 256 MB ext4 filesystem runs the one-shot network initializer, so the
workspace's writable disk is never mounted into two containers simultaneously.
There is no host port publishing in this first version.

## Security and lifecycle

Exactly four entitlements: App Sandbox, virtualization, outgoing network, and
user-selected read-only files for image/installer import. There is no incoming listener,
host directory share, clipboard bridge, camera/microphone, Docker socket, Agent
Host escape, or Noodle connection. NAT can reach LAN resources; the create dialog
offers networking off for Shell and does not claim internet-only isolation.

Records and disks live in the app's private Application Support directory. A
process-held library lock prevents two app instances opening the same disks.
Computer IDs determine paths, never user-entered names. Imports use staging and
atomic publication. Guest files and packages survive restarts; running state is
not restored automatically. Interrupted creations remain unpublished. Deletion
requires confirmation and moves stopped computers to Trash. Stop warns
about unsaved guest data. Quitting stops VMs, with a bounded shutdown deadline.

`ComputerCore` contains Foundation-only records and persistence. Runtime objects
are separate from views; a future provider extension can call that layer without
redesigning the library. No extension, agent skill, remote API, or iOS app is
implemented in this version.

## Verification

`swift test --disable-sandbox --package-path Computer --scratch-path .build/computer`

For the opt-in signed integration test, execute
`".build/Noodle Computer.app/Contents/MacOS/NoodleComputer" --self-test`.
It creates a separate temporary library, downloads Alpine/vminit, starts a VM,
tests DHCP and guest package installation, restarts and verifies disk contents,
then validates an EFI VM configuration. It never opens the user's library.
This does **not** substitute for installing and testing a full macOS/Linux desktop
or Omarchy guest. Test downloads are removed with the temporary fixture library.

Add `--offline` to `--self-test` to test guest execution and disk persistence
without requiring guest networking (initial OCI image downloads still use the
host's network). Use `--configuration-test` to validate a macOS configuration
against Apple's current restore metadata without downloading/installing macOS.
For a separate test app identity/library, build with
`NOODLE_COMPUTER_TEST_BUILD=1 zsh scripts/build-computer.sh`.
`--download-progress-test` verifies actual download progress/cancellation and
cancelled creation cleanup without downloading a complete macOS image.

### Current validation (9 September 2026)

- Core tests cover the two v1 presets, legacy VM compatibility, desktop/legacy template validation, cached-image reuse, size/hash corruption,
  replacement and progress calculation. Signed download tests pass for byte
  progress, cancellation, completed-file ownership and creation cleanup.
  Signed offline integration passes: filesystem sandbox
  denial, actual container boot, guest command execution, stop/restart disk
  persistence, record reload, and EFI configuration.
- macOS restore metadata/hardware model/auxiliary storage/VZ validation pass.
  A full macOS installation and Omarchy desktop have not been verified.
- Guest DHCP, command execution and outbound HTTPS have been verified in the
  official signed app after an authorized restart of the host's stuck NAT service.
  The app itself never modifies that service or widens its entitlements.
- The Launcher desktop has been booted and visually checked through the app's
  embedded WebKit viewer, including its authenticated, certificate-pinned
  connection and live desktop canvas.

`--desktop-smoke-test` verifies the Launcher desktop in an isolated temporary
library: Xvnc/Openbox, authenticated HTTPS, certificate pinning and a connected
WebKit canvas. Failed runs retain that fixture for diagnosis and reuse; a passing
run removes it. It does not open the user's computer library.

`--custom-container-test` checks a real nginx image and its HTTP viewer, the recovery
PTY, transparent terminal appearance and a custom image without a web port.
`--creation-form-test` checks disclosure hit areas, content-sized sheets, matching
Shell/WebKit bounds, outer margins, native toolbar sizing, retained page state,
Stop confirmation and terminal scrollbar visibility. Desktop smoke testing also pauses Xvnc and
verifies that recovery terminal input and session-preserving switching still work.

### Noodle UI parity

The icon and background editors use Noodle's `ImageSourceMenu` control (ported
from `4e7e4ff`), including matching 20-point labels and equal flexible widths for
Choose/Create Image. Keep that control aligned with `Sources/Noodle/ImageSourceMenu.swift`.
The existing `Tests/image-source-menu.swift` regression can also be compiled with
`Computer/Sources/NoodleComputer/ImageSourceMenu.swift`; it checks both chooser
titles at three widths, enabled/disabled sizing and independent File/Photos actions.
The destructive button is likewise identical to Noodle's native control.
