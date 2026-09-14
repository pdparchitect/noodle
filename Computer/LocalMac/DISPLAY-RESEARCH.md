# Account display research — 2026-09-14

## Result

No verified way was found to give the retained background account an arbitrary
desktop size using the current helper's privileges, without affecting the console
display arrangement or depending on Apple's Screen Sharing service.

Diorama supplies selectable virtual monitor sizes, but its registration mechanism
does not establish account-only ownership. Apple's own background virtual display
path is a closer match. Follow-up tracing found that direct control of Apple's
agent is restricted to Apple-signed code. The full Apple server has system-wide
startup behavior; it is not a verified account-contained replacement.

This pass inspected source, binary implementations and public projects. Diorama
was not launched. No display was created or reconfigured, no account was
restarted, no permission was reset, and no system preference or service was
changed. Static findings below are specific to macOS 26.6.2 (25G83), not guarantees
about other macOS versions.

## Diorama

Inspected the sibling repository's `Sources/Diorama/VirtualDisplayController.swift`
and `Sources/CGVirtualDisplayShim/include/CGVirtualDisplay.h`.

- `create(preferred:)` constructs `CGVirtualDisplayDescriptor` and applies a
  list of modes with `hiDPI = 1`. The declared descriptor and creation flow have
  no account UID or login-session selector.
- Its mode sizes are logical points, with Retina backing pixels. This is useful
  if a correctly scoped display can first be established.
- `apply(_:)` completes mode changes with `.permanently`. Do not copy that
  persistence choice into an account-display experiment.
- Creating a monitor is distinct from associating it exclusively with the
  background login. The earlier Noodle experiment already found that creating
  `CGVirtualDisplay` in the background account exposed the monitor in the main
  session. This pass did not repeat that experiment.

## Local macOS implementation

### Apple's background virtual displays

`ScreensharingAgent` constructs `SLVirtualDisplayConfiguration`, sets type 4,
and uses `SLVirtualDisplay`. Its `SSAgentVirtualDisplay` code handles logical
dimensions, backing pixels, mode lists and dynamic resolution.

In SkyLight, the off-console branch of
`WS::Displays::CAWSManager::virtualDisplayCreate` checks
`com.apple.private.SkyLight.virtualdisplay`. The existing desktop helper does not
have that private entitlement. This is an authorization check in the server,
not a missing width/height parameter in Noodle's code.

There is local IPC: the agent expects launchd, looks up
`com.apple.screensharing.server`, and exchanges Mach ports with that server.
The `com.apple.screensharing.agent` XPC listener handles a test string, used by
the daemon to wake the agent. Display configuration goes through a separate
Mach RPC channel, not that XPC message.

### Follow-up: the local RPC sender restriction

The agent's `agent_SSAgent_Checkin_rpc` extracts the sender's PID from the audit
token and passes it to `IsCodeSignatureValid`. That routine loads Security
framework, resolves `SecCodeCopyGuestWithAttributes` and `SecCodeCheckValidity`,
and checks the caller against `anchor apple`, with alternative requirements for
Apple's own production/development/store signatures. It does not accept an
arbitrary Developer ID signature. Apple's
[requirement-language documentation](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/RequirementLang/RequirementLang.html)
distinguishes `anchor apple` from the broader `anchor apple generic`.

Successful check-in sets an internal flag. The
`agent_SSAgent_SetDisplayConfiguration_rpc` handler checks that flag, then looks
up an existing viewer and its display/stream state. It is not an independent
width/height service that the root Noodle helper can call directly. The agent
also watches the checked-in server PID and exits when it goes away.

Read-only validation with `codesign --verify --test-requirement` against the
combined accepted signature requirements produced:

| Installed executable | Result |
| --- | --- |
| Apple's `screensharingd` | Pass, exit 0 |
| Noodle `LocalMacService` | Requirement not satisfied, exit 3 |
| Noodle `LocalMacDesktop` | Requirement not satisfied, exit 3 |

This checked signatures on disk, not a live RPC connection. The initial sandboxed
verification could not reach trust services (`CSSMERR_TP_NOT_TRUSTED` even for
Apple's server); the permitted read-only check outside the sandbox produced the
results above. No executable was launched or re-signed.

The binary also contains a system-wide debug override in the check-in path. It
was not enabled or used and is outside the account-only design constraints.

### Follow-up: running Apple's full server locally

The installed launchd job `com.apple.screensharing` declares both the named Mach
service and a VNC listener with Bonjour. Its `server_init` expects launchd
check-in data containing `Sockets` / `Listener`, retrieves the listener file
descriptors, and then retrieves `com.apple.screensharing.server`. Omitting the
sockets is an explicit startup error. No standalone command-line display mode
was established.

There are system-wide effects beyond listening on a network port:

- The daemon's main startup path creates or changes ownership/permissions of
  `/Library/Application Support/Apple/Screen Sharing`, `Keys` and
  `Shared Settings`, and prepares server key material.
- `StartAllScreensharingAgents` uses a shared launch notification or the shared
  `/private/etc/com.apple.screensharing.agent.launchd` marker. The installed
  agent job accepts both Aqua and LoginWindow sessions.
- The daemon has a `VNCOnlyLocalConnections` preference in
  `com.apple.RemoteManagement`. Its TCP accept handler checks whether the
  connection is local and closes rejected connections. This is an accept-time
  filter, not a change to the launchd listening address and not an IPC-only mode.

Consequently a loopback-restricted deployment of the real server is a different
proposal from reusing an account-local agent. Its complete listener scope
(including media), permissions, shared startup state and cleanup have not been
validated. No server or agent was started during this investigation.

### Existing fallback framebuffer

`CAWSManager::select_display_set` contains a path that makes a virtual copy of an
eligible display. This is consistent with the retained account inheriting the
physical monitor's 3440 × 1440 geometry, although this pass did not trace a live
login through that branch.

The same function reads `DefaultVFBWide`, `DefaultVFBHigh`, `DefaultVFBFormat` and
`DefaultVFBScale` in its fallback path when there is no eligible donor display.
The defaults are 1920 × 1080, BGRA and scale 1. Width and height alone do not
override the earlier copy path or resize an existing display.

`WSIntegerPreferenceForKey` can consult the current session's preferences before
falling back to server preferences. Therefore these keys should not be described
as necessarily system-wide. The limitation is when they are consulted.
`SkipInternalDisplays` and `SkipExternalDisplays` are read during display-manager
initialization; they have not been established as safe account-local controls.
No preference experiment was performed.

### Older resolution interfaces

`SLSConfigureDisplayResolution` accepts a floating-point scale value and emits
configuration command 6; it does not accept arbitrary width/height. In this
build, `configuration_engine::config_via_client_api` routes command 6 to error
1006, `kCGErrorNotImplemented`. Its exported symbol is not evidence of a working
resolution control. This conclusion comes from disassembly, not a setter call.

`CAWSManager::select_virtual_mode`, `toggle_virtual_online_state` and
`move_virtual_cursor` are empty return stubs in this build.

## External implementations

- [iShareScreen](https://github.com/renegadelink/iShareScreen) implements a client
  for Apple's high-performance Screen Sharing. Its
  [protocol research](https://github.com/renegadelink/iShareScreen/blob/main/docs/apple_vnc_rfc.md)
  documents `SetDisplayConfiguration` (0x1d), mode descriptors and dynamic
  resolution. It is a useful lead into Apple's implementation. The supplied
  client requires Screen Sharing enabled on the host, so it does not itself
  satisfy the local-only, no-service-enable requirement. Documentation includes
  both verified and inferred protocol details; do not treat all fields as proven.
- [macos-rdp-server's virtual display code](https://github.com/grioghar/macos-rdp-server/blob/master/display/VirtualDisplay.m)
  creates `CGVirtualDisplay`, places it at the main-display origin, and moves
  the physical monitor aside. “Per-session” here does not demonstrate ownership
  by a separate macOS login. Inspected revision:
  `08db69123d94fb492788128baac84c3f199eacda`.
- [Chromium's virtual display utility](https://chromium.googlesource.com/chromium/src/+/HEAD/ui/display/mac/test/virtual_display_util_mac.mm)
  is another implementation of the ordinary `CGVirtualDisplay` approach, without
  an account selector in the descriptor it declares.

No external code was executed or incorporated into the application.

## Remaining question and acceptance criteria

The direct Noodle-controller-to-Apple-agent proposal is ruled out under the
current constraints by its caller-signature requirement. Administrator privileges
alone do not change the accepted signing identity. Do not treat further message
format reverse engineering as a way around that prerequisite.

Using Apple's actual server would be a separate architecture decision requiring
broader system setup. This research does not establish that an isolated instance
can work without its shared startup effects. No proven alternative satisfying
the current account-only and no-system-change constraints was found.

Any eventual experiment must demonstrate a real account desktop mode such as
1280 × 800 logical points, a monitor absent from the main account's display list,
an unchanged physical display arrangement, correct capture/input coordinates,
and removal without changing the account's retained permissions. Resizing an
encoded frame, magnifying a crop, or rearranging the main user's monitors does
not meet these criteria.

## Review of the supplied second opinion (2026-09-14)

The review correctly identifies `LocalMacDisplay` as encoder dimensions, not a
virtual-display configuration: 3440 × 1440 fitted to 1280 × 800 contains roughly
1280 × 536 pixels of desktop. The source now states that distinction explicitly;
the retained account's `display` JSON key is unchanged.

Region capture and native zoom/pan are reasonable readability improvements.
Apple documents [SCStreamConfiguration.sourceRect](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/sourcerect)
for selecting a capture region. This would require a common transform for
capture, pointer events and screenshots, and limits on region size and queued
frames. The existing 12 MiB limit applies to the entire JSON packet (including
base64 expansion), not raw JPEG bytes; it does not guarantee that arbitrary
full-resolution frames fit. This review does not implement crop/zoom or imply
that doing so changes the account display's geometry.

Automatically clamping application windows would also need explicit product
design: menus, Dock, notifications and system dialogs can appear outside a crop.
No window-clamping behavior or Screen Sharing service enablement was added.

The suggestion that a background copy may inherit the built-in-display flag is
plausible but unverified on this device. The second agent did not run a live Mac
probe. Keep the built-in rejection and main-display exclusion until a separate
built-in-only configuration proves which IDs and flags belong to each session.
Do not disconnect the user's monitor merely to perform that test. The evidence
still establishes no verified independent-display route within our constraints;
it is not a proof that every possible future macOS route is impossible.

## Local evidence for follow-up

Temporary artifacts live under `.build` and are not release dependencies:

- `localmac-skylight-disassembly.txt`: `virtualDisplayCreate` entitlement check
  near unslid address `0x18712F488`; command-6 rejection at `0x18704F8F0`;
  `select_display_set` and `WSIntegerPreferenceForKey` for fallback preferences.
- `localmac-display-agent-disassembly.txt`: launchd requirement near
  `0x10001FE24`; server lookup at `0x100020098`; virtual-display configuration in
  `SSAgentVirtualDisplay`.
- `localmac-display-research/display-constants.txt`: runtime-read CFString
  values confirming entitlement and fallback-key names. The probe loads the
  framework and reads constants; it does not create a display.
- `localmac-display-research/`: downloaded source snapshots used for comparison.
- `localmac-display-research/screensharingd-disassembly.txt`: launchd/socket
  requirements at `0x10000B678`; shared directory operations at `0x10000B450`;
  `StartAllScreensharingAgents` at `0x10000A484`; local-connections preference
  read at `0x10006C720` and rejection path near `0x100030EA0`.
- `localmac-display-agent-disassembly.txt`: check-in at `0x10000F038`, signature
  validation at `0x100029C34`, Apple requirement at `0x100029FE0`, and guarded
  display-configuration handler at `0x10001C1F4`.
- `localmac-display-research/sender-signature-check.txt`: read-only verification
  results for Apple's server and the two installed Noodle helpers.
