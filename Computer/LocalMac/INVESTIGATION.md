# Initial Local Mac investigation

Historical observations from the initial implementation. These describe the
installed prototype before the cleanup; see [README.md](README.md) for the current
architecture and validation requirements.

The later read-only investigation of Diorama, account display sizing and Apple's
display interfaces is recorded in [DISPLAY-RESEARCH.md](DISPLAY-RESEARCH.md).

### Development verification — 2026-09-14

- Signed development build installed at `/Applications/Noodle Computer.app`;
  strict signatures, unchanged main-app entitlements and system-only helper
  linkage verified. The previous installed app is backed up under `.build`.
- 82 Computer tests and 11 LocalMacCore tests passed, including file metadata,
  version checks, traversal/symlink rejection, atomic upload publication,
  cancellation, non-overwrite behavior, copy/rename and repeated folder reads.
- The retained **Local Mac Development** library entry was created through the UI.
- Direct registration from the sandboxed app was rejected by macOS. The separate
  setup app registered the fixed job and the user approved it through Login Items.
  Registration stayed approved across the development-signed updates tested here.
  The later Developer ID transition required refreshing the launch constraint in
  Login Items; see README.md. A command-line reload
  unregistered successfully but macOS refused command-line re-registration;
  **Enable Account Helper** in the native setup app completed it without another
  password prompt. Do not use command-line reload during a running account session.
- Fixed daemon startup to resolve its executable through dyld, because launchd
  supplies a relative command name. Absolute and relative command-name layout
  checks pass. Fixed Open Directory creation values to use attribute arrays.
- Account `noodle_e73f24aa61044f269b44` was created as standard UID 502, and its
  off-console desktop helper is running. The existing reserved identifier and
  credential were reused after the failed setup; no account was deleted.
- Files view lists the account's home. The native terminal works: user-driven
  `pwd`, `whoami`, directory listing and navigation show the separate account and
  its home/workspace. The user explicitly approved Screen Recording and
  Accessibility for **Noodle Local Mac Desktop**. Both grants are enabled
  (shown as `LocalMacDesktop` in System Settings). The subsequent reconnect kept
  the same account but capture remained denied: TCC logs attributed the request
  to the root lifecycle service instead of the approved desktop app.
- A signed, hardened-runtime process probe verified that disclaimed SETEXEC
  makes the process responsible for itself while retaining its PID. Real TCC
  logs then confirmed Accessibility/PostEvent accepted the helper, but Screen
  Recording still mapped the nested app to its enclosing Computer app.
- The account-local signed runtime copy resolved Screen Recording too. TCC logs
  show all three grants accepted for the desktop helper with no new permission
  prompt. Live frames now appear in the native viewer; advancing the optional
  Accessibility page visibly updated the stream to Data & Privacy. The user
  confirmed the picture. Updates reuse this runtime path and signed identity.
- Mouse clicks now work, confirmed by the user. Two independent defects were
  fixed: reading scroll-only NSEvent properties discarded ordinary pointer
  events, and a hidden Notification Center window intercepted target selection.
  Regression tests cover both, plus mapping through aspect-fit padding. Visible,
  nontransparent account windows initially received process-targeted input with
  AXPress for standard controls. This was insufficient for Dock interaction and
  dragging and has been replaced by the verified background-session event route.
- The account-only display has a different ID and is invisible to the main
  account's display query. It does not offer a 1280 × 800 public display mode.
  Enumeration including duplicate low-resolution modes offers only 3440 × 1440.
  No mode was changed; capture remains a scaled view of its larger desktop.
- Read-only tracing of this build's SkyLight and ScreensharingAgent found the
  newer off-console virtual-display creation path checks
  `com.apple.private.SkyLight.virtualdisplay`. No private entitlement was added.
  The `com.apple.windowserver.virtualDisplayWidth/Height/Resolution` strings are
  parameters to the AirPlay display-creation path, which checks for the console
  session; they are not a verified per-account resolution preference.
- Per-user onboarding history alone still launched the Apple Account page.
  Adding `~/.skipbuddy` and reconnecting the retained account opened Finder and
  Dock directly, with no Setup Assistant process and no setup-page clicks.
  The marker is also documented by [XCreds](https://twocanoes.com/knowledge-base/whats-new-in-xcreds-5-5/)
  and is referenced by this OS build's `mbuseragent`. Fresh-account provisioning
  uses the same preparation before login; no additional account was created to
  test that path. A running older lifecycle service needs to restart to load it.
- The final signed update was installed and reconnected: Finder/Dock appear
  without Setup Assistant, and the viewer has neither resolution banner.
  An account-helper refresh through Login Items requested administrator
  authentication; it was cancelled, leaving the existing approval enabled.
  The older lifecycle process remains active until its next restart. The
  retained account already has the marker, so its automatic desktop startup
  does not depend on that refresh. Preparation invoked from the main UID was
  verified to fail before touching that user's onboarding preferences.
- Main-session baseline: UID 501 remains on-console; `/dev/console` is UID 501,
  GID 20, mode 0622; the physical display is 3440 × 1440 (display ID 2).
- After background login, the main session and console metadata still match the
  baseline. Its active display remains ID 2, 3440 × 1440 at origin (0, 0).
- Retained-account stop/restart works without another password prompt. The
  account's loginwindow now reads `idleTime: 0` at login and exits its idle-screen-
  saver check without scheduling the old timeout. Main-user preferences remain
  unchanged. The native terminal uses `workspace %`.
- The shared file browser's Home shortcut opens Applications, Desktop, Documents,
  Downloads, Library and workspace in the retained account. Root and non-root
  Linux account resolution also passes NSS fixture tests (not a fresh VM test).
- The signed input update was tested through the actual native viewer: dragging
  the Finder title bar moved its window; clicking Safari in the Dock brought it
  to the foreground; Command-L selected the account Safari address field. The
  ordinary stopped screen and banner-free desktop were verified visually.
  Dragging an empty test file into a Finder folder was also verified by its
  resulting on-disk path in the account terminal. Every keyboard combination
  has not been verified.
  Independent 1280 × 800 desktop geometry and dynamic resolution remain unresolved.

- Whole-display capture was installed and verified in the retained account: live
  frames continue, Finder/Safari/TV have their ordinary traffic-light controls,
  and the per-window sharing pills are gone. No system settings, capture grants
  or signing entitlements changed.
