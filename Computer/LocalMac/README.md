# Local Mac backend — experimental

Local Mac runs a retained standard account's off-console desktop on the host Mac.
The account shares the host kernel, resources and network. Filesystem access from
its shell follows macOS permissions; it is not virtual-machine isolation.

## Development alongside the installed app

Use `scripts/build-and-launch-computer.sh` for Noodle Computer Dev, paired with
Noodle Dev. It has a separate library and a separately approved Local Mac
service. The launcher installs it in `/Applications/Noodle Computer Dev.app`;
managed standard accounts cannot execute a helper inside the owner's private
Documents folder. A symlink at the former build location preserves existing
development service references. The service checks helper access as the managed
user before attempting background login. Its setup, lifecycle and desktop helpers use
`com.pdparchitect.noodle.computer.local.*` identities, its App Group ends in
`.computers.local`, and its root-owned records live under
`/Library/Application Support/Noodle Computer Local/Local Mac`. Its System
keychain service is `com.pdparchitect.noodle.computer.local.localmac`.

Production identities and retained accounts are unchanged. Create new computers
in the Dev library; do not copy production account records. The managed local
account uses `Noodle Local Mac Desktop Dev.app` with separate capture/control
permission identity. Test fixtures cannot register an account service.

## Components and boundaries

Local Mac is available beside New Container and New from Container Image in
both creation menus. Its separate form uses the shared icon/background editors
and honors Start new computers automatically. It does not offer container images
or virtual hardware settings. The sidebar and normal start/stop controls use the
name Local Mac; compatibility limitations are documented here.

- `LocalMacSetup` registers only its bundled lifecycle service with SMAppService.
  Its macOS display name is Noodle Computer Setup for production and Noodle
  Computer Dev Setup for development. Localized bundle names keep these labels
  distinct without moving the registered helper or changing its service identity.
  Its read-only `--registration-status` query reports that service's SMAppService
  state without creating a window, registering or requesting approval. It accepts
  no maintenance commands, account IDs, credentials or executable paths.
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

The desktop toolbar's **Focus Window** button opens the account's focused window
in an independent, resizable interactive window. It can be used repeatedly for
different windows; opening the same window again brings its existing view forward.
**Open All Windows** opens the currently visible root application windows, including
separate documents in the same app. It is a snapshot action, not an automatic
subscription to future windows. Hidden and minimized guest windows are excluded.
New views tile alongside existing previews on their host monitor, leaving the
menu bar and Dock clear. Open All Windows also restores minimized host previews
and re-tiles them. Views moved to another monitor stay there. Manual moves and
resizes are preserved until another view is added or Open All Windows is used;
incoming capture frames never undo the layout.

Root discovery combines the account's Accessibility window hierarchy with its
visible window list and verified display. Sheets, drawers, popovers and floating
UI enrich their owning root's capture instead of becoming separate views. Child
content extending beyond its parent remains in the crop. Unmatched or ambiguous
roots are omitted. Focus Window retains its independently verified focused-window
fallback when optional ancestry is unavailable. Clicking the host toolbar does
not change the account's focus, and the helper rechecks each requested identity.

Each opened window owns a display-bound ScreenCaptureKit stream with child windows
enabled. The streams share a 16-megapixel capture budget, capped at native scale
and 8192 pixels on either axis, with up to 32 open views. Transparent margins are
cropped before encoding. Frame backpressure is independent per window. The
desktop's 1280 × 800 stream and saved screenshots are unchanged. Window capture
may display macOS sharing controls on the selected guest windows.

Each frame carries its crop geometry and preview identity. Input uses the geometry
of the displayed frame, including aspect-fit padding. Selecting a host window
activates its exact guest root before forwarding input, including when several
windows belong to the same app. Hover events do not activate another window.
Held input is released when focus changes; closing an inactive view does not
release another view's input. Late frames and errors cannot replace a sibling
window or the desktop.

Opened windows stay available when switching computers, Terminal or Files in the
main library window. Closing a host view leaves the guest application running.
Closing or minimizing the guest root, or losing its desktop connection, ends the
corresponding view. New sheets and dialogs remain with their root as they open
and close. System-owned dialogs may require returning to the desktop; content
outside the account display cannot be interacted with through these views.
The private desktop wire protocol is version 3; stop and start retained connections
after updating both app and helper.

## Account preparation and permission identity

Before first login, the service invokes the signed desktop helper as the managed
user to prepare that user's home. The helper also prepares retained accounts on
launch. Preparation verifies the real account home and identity, then:

- creates `~/.skipbuddy` and seeds per-user Setup Assistant presentation history;
- sets per-user screen-saver `idleTime` to zero for current-host and any-host scopes;
- creates `.zshrc` only when absent, with `PROMPT='%1~ %# '`, and appends the
  interactive welcome hook once to ordinary account-owned `.zshrc` files.

This preserves existing shell customization and changes neither the main user's
preferences nor system power/password policy. Manual locking remains available.

The welcome uses the same bundled ASCII banner as the container images, in both
Noodle's terminal and Terminal.app inside the managed desktop. New account shell
hooks select the runtime helper name from the build identity, including the Dev
suffix; they never depend on a production helper being installed. It prints once per
interactive shell with a terminal attached; non-interactive commands stay silent.
Set `NOODLE_BANNER=0` before the hook to disable it. Custom linked or read-only
shell configuration is left alone.

On this macOS build, nested helper apps inherit their enclosing app's Screen
Recording attribution. The helper therefore verifies and maintains a signed copy
at `~/Applications/Noodle Local Mac Desktop.app`, then re-execs with disclaimed
spawn responsibility. It retains the account, PID, audit session and inherited
pipes. macOS still requires that helper's own capture/control grants; none are
automatically granted or reset.

The computer's permission settings reveal a verified standalone copy under the
owner app's sandbox Application Support/Local Mac Permissions folder. It has the
same bundle identifier, signing requirement and CDHash as the bundled desktop
helper used to prepare the managed runtime. Selecting a nested helper in System
Settings can resolve to the enclosing Computer app; the standalone copy avoids
that ambiguity without opening another user's private home. Preparing/revealing
this copy does not execute it, register a service, or request/change a grant.
The desktop handshake remains connected while capture/control permission is
missing, and starts capture only after the helper reports those grants.

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
Mac Desktop Dev in the managed account**, not for the main user's terminal. Existing
denials can require changing that account's Files & Folders settings; adding a
description does not grant permission or reset a denial. Library has additional
macOS protections and is not universally readable. Do not use chmod, global Full
Disk Access or TCC database edits as a substitute for account-scoped consent.

Assigned agents use the existing list/start/open/read/write/resize/close,
upload/download and present commands. Present creates a saved native reference;
Noodle does not receive the live desktop stream. Direct desktop input is not yet
an agent CLI operation. Linux-specific browser/Puppeteer instructions do not
apply to this account.

AppleScript commands in the account terminal use the standalone desktop helper's
Automation consent identity. The helper carries the Apple Events entitlement and
usage description so it can request approval for target apps. Approval remains
per target app in the managed account; the entitlement does not grant access or
reset an earlier denial. Neither the main Computer app nor the privileged service
receives this entitlement. The signed-bundle checks require it on the desktop
helper and reject additional helper entitlements. Background-account consent
prompts may still require the user to interact with that account; a terminal error
alone does not distinguish a denied request from a prompt that could not complete.

## Compatibility and updates

The creation form and startup check the registrar's actual status. An unregistered
service shows Enable Local Mac; pending or revoked approval shows Open System
Settings. These are setup states, not failed computers. ServiceManagement may
report `notFound` before a service has ever registered; the query first checks the
bundled plist and executable so this first-use case still offers setup, while an
incomplete bundle reports a missing helper. Returning to Computer refreshes the
state without starting an account or clearing an unresolved helper failure. An enabled but unresponsive
helper still offers registration recovery. If the read-only status query fails
or times out, the app reports that the status is unknown rather than claiming a
permission denial. Desktop capture/control permissions are checked separately by
the helper inside the managed account once it can start.

Deletion is available for a running or failed Local Mac as well as a stopped
one, except during a lifecycle operation. After explicit confirmation, the root
service stops the owned background session and verifies logout before removing
anything. A failed desktop pipe is not needed for this lifecycle operation. Stop
failure or cleanup failure retains the library/account records for recovery.

Deletion checks the exact managed home and walks its directories without changing
files before cleanup begins. A privacy denial while opening or enumerating a
folder offers Full Disk Access for the matching Computer app in the owner's
System Settings. The root lifecycle service still needs macOS privacy approval;
Login Items approval and the managed desktop's capture permissions are separate.
This access is only requested after a failed explicit deletion, never granted or
changed automatically. The UI opens Settings only on click and never retries
deletion on return. On macOS 27 the denial is attributed to the containing
Computer app, so development recovery names **Noodle Computer Dev**.

The preflight catches inaccessible directories and locked items before removal;
it cannot make recursive deletion atomic if contents or permissions change during
cleanup. Errors report the failed relative path and whether removal had begun.
Account/credential/ownership records remain until the whole home is removed.
Traversal never follows symlinks or crosses filesystems and rechecks entry
identity before unlinking. The XPC `removeAccount` selector adds a structured
deletion failure alongside the readable fallback; the old `remove` selector
remains available. The client verifies the installed service before sending
deletion once. Tests use temporary synthetic homes, never real managed accounts.

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
lifecycle service during ordinary startup: that can interrupt desktops and require
approval again. **Repair Local Mac** in Setup verifies the installed app and helper,
waits for macOS to unregister the old service completely, then registers the
current one. A bounded retry handles macOS briefly retaining a disabled registration
after shutdown; explicit approval and signature failures are not retried.
Repair disconnects active Local Mac desktops while retaining accounts,
files, credentials and privacy grants. If macOS requires approval, Setup opens Login
Items. Return to Computer and retry the operation after approval. Repair never
repeats account creation or deletion. The service checks its fixed installed
executable against its exact signing identity.
An independent timer checks the signed contents and executable file identity for
a verified replacement, including an identical reinstall, without needing an XPC
request to reach the old executable. When it finds one and has no active desktop
children or account operation, the helper exits; launchd loads the replacement
through the same approved job. A version query can also trigger this check, draining
its reply before exit. Missing or invalid replacement code never triggers retirement.
Lifecycle operations are refused once that restart begins. The client retries
only this read-only handshake, with a bounded wait. It sends `serviceInfo`
directly, without a separate `check` gate: after an atomic app replacement,
macOS can reject replies from the old executable before its restart response is
delivered. Transport failures are retried within the same bounded handshake;
protocol, fingerprint and explicit service errors are not accepted as readiness.
XPC signing requirements remain in force on every connection. Active desktops defer service
replacement until they close; account operations are never blindly replayed.

**First upgrade from the prototype:** a daemon without `serviceInfo` cannot be
taught to restart by an updated app. A normal Mac restart can replace that process,
but it cannot repair launch constraints saved for a different signing category.
The client runs a bounded version handshake before account operations and offers
Repair Local Mac if an enabled helper cannot be reached or verified. Setup refreshes
the installed helper's registration using the asynchronous ServiceManagement API,
including helpers that predate independent update detection. macOS
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

Focus Window resolves the selected accessibility element through AXWindow and
AXParent to the owning root window, with bounded traversal and process checks.
Ancestry is optional: the focused window is independently matched first, and
remains available if an ancestor is unreadable, times out, or cannot be matched.
Only transient dialogs/panels may fall back to the application's declared main
window; ordinary documents remain separate. Capture includes that root and its
related popup windows, follows popup changes, and retains the root when a dialog
closes. Invalid/cyclic ownership cannot select another process's windows.
