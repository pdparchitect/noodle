# Local Mac backend — experimental

Local Mac runs a retained standard account's off-console desktop on the host Mac.
The account shares the host kernel, resources and network. Filesystem access from
its shell follows macOS permissions; it is not virtual-machine isolation.

## Components and boundaries

Local Mac is available beside New Container and New from Container Image in
both creation menus. Its separate form uses the shared icon/background editors
and honors Start new computers automatically. It does not offer container images
or virtual hardware settings. The sidebar and normal start/stop controls use the
name Local Mac; compatibility limitations are documented here.

- `LocalMacSetup` registers only its bundled lifecycle service with SMAppService.
  It accepts no maintenance commands, account IDs, credentials or executable paths.
- `LocalMacService` owns account creation/resume, background login, connection,
  stop and explicit deletion. XPC checks the exact client signing identity and
  binds each request to the caller UID. Ownership records are root-private;
  generated passwords stay in the System keychain. Stop retains the account.
- `LocalMacDesktop` runs as the standard account. `AccountCapture` handles
  ScreenCaptureKit; `AccountInput` handles events; `Terminal` handles PTYs;
  `LocalMacFileStore` handles files. The root service hands over inherited pipes
  and never interprets these commands or data.
- The Computer app supplies the native desktop, existing terminal and shared
  `ComputerFilesView`. The Noodle provider adapts its existing agent CLI to this
  backend. No separate file browser or recurring setup screen is needed.

The main app keeps its existing App Sandbox. Setup, lifecycle and desktop helpers
are separately signed, hardened-runtime unsandboxed exceptions with no optional
entitlements. They are required for service registration, privileged account
management and the account's ordinary desktop/shell respectively.

The verified main-app entitlements are App Sandbox, outbound network client,
virtualization, user-selected read/write files, App Group
`S8VNVK39LH.com.pdparchitect.noodle.computers`, and Mach lookup for only the existing
Sparkle `com.pdparchitect.noodle.computer-spks` and `-spki` services.

The desktop helper verifies UID, username, audit ID and unique off-console session
identity before operations and every captured frame. Input enters only
`cgSessionEventTap`, never the physical HID tap. Motion coalescing preserves
button/key transitions, and focus loss releases held input. App shortcuts are
captured while the native view is focused; Control-Option-Escape releases focus.
macOS-reserved shortcuts such as Command-Tab still reach the host.

There is no TCP listener, Screen Sharing/Remote Management enablement, host
clipboard bridge or TCC database editing. CLI assignments restrict which agents
can access a computer; agents have separate PTYs but share its account and files.

## Capture and resolution

Capture begins with a version-checked connection and an explicit list of the main
session's display IDs. The account helper accepts exactly one non-built-in display
outside that list. Whole-display capture includes desktop and Dock without
putting sharing controls over every window's traffic-light buttons.

Capture state is isolated to the main actor across asynchronous operations;
ScreenCaptureKit sample callbacks arrive on its configured main queue.
The client checks display separation on status updates and before showing frames.
Losing that verification closes the connection and clears the preview. Capture
failures are reported separately from shell/file availability.

The current encoded output is 1280 × 800, preserving aspect ratio, at up to 12 fps.
This is the preview size, not a claim about the account display's actual geometry.
Capture does not attempt display creation or mode changes. On the development Mac,
the account display still reports 3440 × 1440. Independent smaller geometry and
dynamic resolution remain future work; they should be separate from capture.

## Account preparation and permission identity

Before first login, the service invokes the signed desktop helper as the managed
user to prepare that user's home. The helper also prepares retained accounts on
launch. Preparation verifies the real account home and identity, then:

- creates `~/.skipbuddy` and seeds per-user Setup Assistant presentation history;
- sets per-user screen-saver `idleTime` to zero for current-host and any-host scopes;
- creates `.zshrc` only when absent, with `PROMPT='%1~ %# '`.

This preserves existing shell customization and changes neither the main user's
preferences nor system power/password policy. Manual locking remains available.

On this macOS build, nested helper apps inherit their enclosing app's Screen
Recording attribution. The helper therefore verifies and maintains a signed copy
at `~/Applications/Noodle Local Mac Desktop.app`, then re-execs with disclaimed
spawn responsibility. It retains the account, PID, audit session and inherited
pipes. macOS still requires that helper's own capture/control grants; none are
automatically granted or reset.

## Files and agent access

The shared file browser maps `/` to the account home and `/workspace` to its
workspace. Exact absolute paths inside the verified home also work. The shell
uses real macOS paths, including `~/workspace`. File transfers reject symlink
parents, use version checks and publish uploads atomically without replacement.
Cancellation removes unpublished upload data; deletion accepts files or empty
folders. Home resolves through the backend instead of assuming `/root`.

File operations run on a bounded worker, separate from desktop capture and input.
Reads use independent descriptors and run concurrently so one folder's consent
wait does not hold up every other folder. Duplicate listings of the same folder
are refused while its first read is outstanding. Mutations and transfer state
remain serialized; closing rejects new work and drains accepted operations before
cleaning up transfers. Every operation rechecks the account session. Permission,
missing-item and symbolic-link failures have distinct errors; directory
enumeration errors are not treated as an empty folder.

Desktop, Documents and Downloads remain subject to macOS Files & Folders privacy
permissions, even for the account that owns them. The standalone helper includes
usage descriptions for those folders. Access must be allowed for **Noodle Local
Mac Desktop in the managed account**, not for the main user's terminal. Existing
denials can require changing that account's Files & Folders settings; adding a
description does not grant permission or reset a denial. Library has additional
macOS protections and is not universally readable. Do not use chmod, global Full
Disk Access or TCC database edits as a substitute for account-scoped consent.

Assigned agents use the existing list/start/open/read/write/resize/close,
upload/download and present commands. Present creates a saved native reference;
Noodle does not receive the live desktop stream. Direct desktop input is not yet
an agent CLI operation. Linux-specific browser/Puppeteer instructions do not
apply to this account.

## Compatibility and updates

`LocalMacWire.version` versions the private app-to-desktop protocol. Both sides
check the version before decoding operations. The client checks status before
starting capture; an unversioned or incompatible helper fails with an update and
reconnect instruction. The privileged XPC interface retains its original `check`
selector and adds a versioned `serviceInfo` handshake before lifecycle mutations.
The client compares the running service's signing fingerprint with the verified
service inside its installed app, not just a marketing version number.

Keep the installed app path, signing identity, account and permission identity
stable. Build and verify before replacing the app. Close the app's active
connections before updating and start them again afterward so the client and
signed desktop copy use the same protocol. Do not automatically unregister the
lifecycle service during ordinary startup: that can discard its approval and
interrupt desktops. Explicit registration repair is available in Local Mac Setup
when an update leaves the service unable to launch. The service checks its fixed
installed executable against its exact signing identity.
When it finds a replacement and has no active desktop children, it drains the XPC
reply and exits; launchd loads the replacement through the same approved job.
Lifecycle operations are refused once that restart begins. The client retries
only this read-only handshake, with a bounded wait. Active desktops defer service
replacement until they close; account operations are never blindly replayed.

**First upgrade from the prototype:** a daemon without `serviceInfo` cannot be
taught to restart by an updated app. A normal Mac restart can replace that process,
but it cannot repair launch constraints saved for a different signing category.
The client probes service availability for five seconds before account operations
and offers Local Mac Setup when the helper does not respond. Setup opens Login
Items and explains how to turn LocalMacSetup off and back on, refreshing the
installed helper's launch constraints without deleting its registration. macOS
may require authentication; account records,
credentials, homes and desktop privacy grants are not removed by this operation.
Restart/reconnect after an actual signed app replacement still requires live
validation; the account-free tests do not prove launchd's update behavior.

**Development-to-release transition observed on macOS 27.0 (26A428):** the retained
0.6.0 launchd job required validation category 3 (development), while the installed
0.7.0 service had category 6 (Developer ID). launchd rejected it with a Launch
Constraint Violation before account login. Strict installed signature and bundle
layout checks passed. This is a stale-registration failure, not evidence about
whether the background-login API works on that OS. The ServiceManagement SDK
requires re-registration after changing a daemon executable; its launch metadata
must be validated as well as the service's own fingerprint handshake. The native
Login Items toggle was verified to refresh the job to 0.7.0/category 6 and allow
the released service to launch.

The same transition exposed a separate credential ACL issue: the password item's
trusted application requirement named the original Apple Development certificate.
securityd rejected the Developer ID service with `errSecInteractionNotAllowed`
before background login. Repair that item's Access Control for the installed
service in Keychain Access; do not reveal/reset the password, recreate the account,
or allow all applications. A stable release-to-release signing identity must be
tested separately; development-to-release migration cannot assume those grants
carry over.

Desktop privacy grants also retained the development certificate in this
transition. System Settings reported successful Screen Recording and
Accessibility grants for the release, but a read-only inspection of the system
TCC records showed the old code requirement was still stored. The runtime copy
had the release identity; TCC rejected it with a code-requirement mismatch.
Adding the same bundle again and restarting the account did not repair this.
For this specific migration, clear only the helper's two stale approvals with
Apple's `tccutil`, then grant the installed desktop helper through System Settings:

```sh
tccutil reset ScreenCapture com.pdparchitect.noodle.computer.desktop
tccutil reset Accessibility com.pdparchitect.noodle.computer.desktop
```

Do not run a service-wide or `All` reset, edit TCC databases, or reset other apps'
permissions. These commands remove approvals; they do not grant access. Confirm
the helper actually reports capture and input access after reapproval and restart
before treating the migration as repaired. See Apple's
[protected-resource reset documentation](https://developer.apple.com/documentation/xcode/resetting-access-to-protected-resources-in-macos).

This scoped reset and reapproval was verified on 2026-09-15: both stored grants
then referenced the Developer ID requirement, the retained desktop returned, and
a reconnect restored input. Clicking into the native preview and sending
Command-L focused Safari's address field inside the account. The account, home,
credential and installed 0.7.0 release were retained. This verifies that tested
recovery on macOS 27.0; it does not establish release-to-release upgrade coverage.

The account's standalone desktop copy is installed under a per-account lock.
The source and staged bundle must pass signing identity and content validation.
An atomic exchange retains the previous copy until the published bundle is
verified. Failed verification rolls back; an interrupted exchange is recovered
on the next Start. A damaged existing copy can be repaired from a verified source.
Neither repair nor update recreates the account or resets permission grants.

## Unsupported macOS dependencies

Private calls are confined to `LocalMacPrivate`: SkyLight session enumeration,
creation/release, and process-responsibility functions. The background login ABI
was investigated on macOS 26.6.2. Setup Assistant history keys are also undocumented.
These dependencies can break across macOS updates; cleanup does not turn them
into supported APIs.

Background login can leave `/dev/console` assigned to the wrong session. The
service records its verified original metadata and restores only that character
device while the original console session is still active. This recovery path
requires particular care in future compatibility testing. Do not broaden it into
system-wide ownership or permissions repair.

## Validation

Run account-free checks:

```sh
swift test --disable-sandbox --package-path Computer/LocalMac --scratch-path .build/localmac
swift test --disable-sandbox --package-path Computer --scratch-path .build/computer
```

Checks cover ownership/session rejection, capture exclusion and authorization,
protocol compatibility, bounded framing, actual client transport over test pipes,
intentional versus unexpected disconnects, stale connection callbacks, file
boundaries/transfers, shared browser navigation and input ordering. Normal builds
verify signatures, helper layout and unchanged entitlements.

Before wider use, validate the signed result in the retained account: live capture,
Dock/drag/keyboard input, terminal/files, assigned-agent CLI access, stop/reconnect,
and app/helper failure recovery. Reboot, sleep/wake and macOS-update coverage remain
outstanding. Tests do not create/delete accounts or reset permissions. Keep the
main desktop and its document access available throughout.

The [initial investigation](INVESTIGATION.md) records observed behavior of the
working prototype, including the unresolved display constraints. It is historical
evidence, not proof that a later refactor has passed the same live checks.

Cleanup validation on 2026-09-14: 94 Computer tests and 25 Local Mac tests passed.
The signed development bundle passed strict verification and the existing
entitlement checks. This build has not replaced the installed app or undergone
a fresh live-account/agent-CLI test. No account or system settings were changed
by the cleanup checks.

At 21:28:17 on that date, targeted TCC logs confirmed a Documents-folder denial
for the standalone helper in managed account UID 502 (`authValue=0`,
`authReason=13`). The old generic symbolic-link error hid that cause. This is
evidence of a privacy denial, not evidence that the new usage descriptions have
resolved it; permission granting in the retained account remains a live check.

On 2026-09-15, the installed 0.7.0 release's account TCC logs showed the old
development requirements rejected for Desktop, Documents and Downloads. Folder
requests then waited on consent and ended with `Denied (Prompt Cancel)`, including
the account terminal's `ls`. The serial file queue filled during those waits;
the workspace became readable again after they ended. The concurrent-read fix
passes 29 helper tests, including a blocked-folder/available-workspace regression,
but has not replaced the installed release. Restoring the managed account's
Files & Folders approvals remains a separate live recovery step.
