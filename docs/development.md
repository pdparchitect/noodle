# Build and test

Run commands from the repository root. You need macOS 26 or later and full Xcode.
For Noodle Computer, see its [development guide](../Computer/DEVELOPMENT.md).

Install the selected Xcode's Metal Toolchain to package the local-model shaders.
Check this component again after upgrading Xcode:

```sh
xcodebuild -downloadComponent MetalToolchain
```

Build and launch the app, or run the smoke suite:

```sh
scripts/build-and-launch.sh
Tests/smoke-test.sh
```

The build creates `.build/Noodle Dev.app` with separate development data. The
smoke suite runs tests and verifies the signed app and helpers. To install the
Dev app in Applications and register its Shortcuts action:

```sh
scripts/install-app.sh
```

The build uses an installed Apple Development identity. Override it with
`NOODLE_SIGNING_IDENTITY`; `-` selects ad-hoc signing.

## Development companion apps

Noodle Dev connects only to Noodle Computer Dev; production Noodle connects
only to production Computer. Build and launch the matching Computer app with:

```sh
scripts/build-and-launch-computer.sh
```

Both launch scripts force separate development containers and reject arguments,
including the former `--production-data` option. Runbar's Noodle and Computer
entries use only these development launchers. Production identity selection remains in
release packaging, which does not launch the app. See
[Computer development](../Computer/DEVELOPMENT.md) for Local Mac setup.

Applet uses the same strict environment pairing: Noodle Dev connects only to
Noodle Applet Dev. `scripts/build-and-launch-applet.sh` (Runbar: **Noodle Applet →
Build & Launch Dev**) forces the development identity. Development documents and links use
`.noodlet-dev` and `noodlet-dev://`; production retains `.noodlet` and
`noodlet://`. Each app and its Quick Look extension registers only its own type.
Use the Applet CLI's explicit `convert --path SOURCE --output NEW_DOCUMENT` to
copy a package between environments; saved runtime data and live links are not
transferred. See [Applet development and conversion](../Applet/README.md#dev-and-production-builds).

## Documentation changes

Message/event guidance, the Messenger skill, and CLI help come from
[`MessengerDocumentation.swift`](../Sources/NoodleCore/MessengerDocumentation.swift).
After editing it, run its tests:

```sh
swift test --disable-sandbox --filter MessengerDocumentationTests
```

Keep every
event's recipients, fields, and handling guidance; update encoding-coverage tests
when payload fields change.

For reader-facing docs, lead with the task and steps. Keep protocol details in
references, link to existing explanations, and omit implementation history and old
test reports. Add user-visible changes to the appropriate Unreleased changelog.

## Coverage

Run the same Noodle checks as CI, with no harness accounts or signing certificate:

```sh
zsh Tests/build-sandbox-cli-fixture.sh
zsh Tests/message-delivery.sh
NOODLE_TEST_CLI_APPLICATION="$PWD/.build/Sandbox CLI Tests.app" \
  swift test --disable-sandbox --enable-code-coverage
python3 scripts/coverage-report.py \
  --input "$(swift test --disable-sandbox --show-codecov-path)" \
  --output .build/coverage/noodle
```

Open `.build/coverage/noodle/summary.md` for module totals and the largest gaps.
The directory also contains a complete file summary and the original SwiftPM
JSON export. To compare against a saved report, pass
`--baseline /path/to/previous/summary.json`; changes are percentage points.

The `Validate and release versions` workflow runs the Noodle, Computer, Applet,
and shared bridge suites for code changes on pull requests and pushes to `main`,
and on manual runs, even when no version changes. Documentation and website
changes follow the [CI path filters](releases.md#what-ci-does). Its macOS 26
runners execute real Seatbelt sandbox processes; `--disable-sandbox` disables
SwiftPM's build sandbox, not the sandbox
profiles exercised by the tests. Version selection still controls release jobs.

Each Noodle CI test job publishes the summary and a
`noodle-coverage` artifact retained for 30 days. Coverage counts root source
modules linked into the test bundle, including app code pulled in by integration
tests, and excludes test code and dependencies. Separate native fixtures do not
contribute to that report.
Reporting does not impose a minimum percentage; test failures still fail CI.

The default suites use temporary repositories, synthetic model folders, fake
runtimes, intercepted HTTP, and disposable sandbox processes. They cover storage,
message delivery, runtime recovery, access controls, and offline audio handling.
They do not require provider accounts or perform live model requests. Native
harness initialization checks skip when their harness is not installed.

`BridgeCLISandboxTests` requires signed Messenger, MCP, and Applet
helpers. Use the fixture and environment variable above to require those checks;
without them, a local run may skip the tests if no development app is available.
The fixture does not launch the GUI or contact remote services. The smoke suite
separately verifies the packaged app and helper signatures.

For focused access checks, use `swift test --disable-sandbox --filter` with
`AppletBrokerTests`, `RestrictedAgentSandboxTests`, `RestrictedClaudeSandboxTests`,
`RestrictedMuseSandboxTests`, or `AppleSandboxTests`. Restricted Claude tests use
the signed CLI and a synthetic local API; prepare the CLI fixture first.

To check the native OpenCode v2 protocol without an account or model request, run:

```sh
NOODLE_TEST_OPENCODE_EXECUTABLE="$HOME/.opencode/bin/opencode" \
  swift test --disable-sandbox --filter OpenCodeTests
```

The fixture verifies the vendor signature, uses synthetic credentials and a local
model definition, checks isolated configuration and tools, and creates/resumes an
ACP session. It does not read the installed account or send a prompt.

Also set `NOODLE_TEST_OPENCODE_PUBLIC_MODEL=opencode/union-alpha` to check the
online catalogue and select that model in a fresh isolated ACP session. This
optional check fetches public model metadata but does not send a model prompt.

### Live checks

These opt-in checks use installed harnesses and real provider accounts. They can
consume model usage. Run them separately from the account-free suite.

| Check | Command |
| --- | --- |
| Harness install from the vendor | `NOODLE_TEST_HARNESS_INSTALL=fx,codex,claude-code,grok-build,muse,opencode swift test --disable-sandbox --filter ManagedHarnessTests` downloads real releases into a temporary folder and runs each one's `--version`; no account is used |
| Restricted ACP Messenger and resume | `NOODLE_TEST_RESTRICTED_ACP=1 swift test --disable-sandbox --filter RestrictedACPLiveTests` |
| Restricted Muse | `NOODLE_TEST_MUSE_RESTRICTED=1 zsh Tests/muse-live.sh` |
| Unrestricted Muse | `NOODLE_TEST_MUSE_LIVE=1 zsh Tests/muse-live.sh` |

Set `NOODLE_TEST_MUSE_MODEL` to select a Muse model; otherwise its default is used.
See [local model checks](#build-and-test-local-models) for Apple and MLX.
Real provider sign-in, token refresh, and remote tool calls need separate checks.

For microphone startup, run
`zsh Tests/voice-startup.sh --live --device-name 'Microphone name'` with the exact
name from Sound settings. It repeatedly starts and stops the selected input and
checks buffer delivery without saving or transcribing audio. macOS may request
microphone access. Without `--live`, the command only builds the fixture.

## Focused checks

Run native UI fixtures from a logged-in Mac. They use isolated test data.

Standalone fixtures link NoodleCore and its shared dependencies through
`Tests/core-link-objects.py`, using SwiftPM's current output maps. This excludes
cached object files left behind when source files are removed.

| Area | Command | Check |
| --- | --- | --- |
| Chat | `zsh Tests/chat-features.sh` | Name menu, profiles, Markdown, draft and keyboard behavior using the production composer; add `--check` for automatic menu/avatar checks without opening the manual fixture |
| Conversation annotations | `zsh Tests/conversation-annotations.sh` | Selected transcript text and region capture in a sandboxed native fixture |
| Attachment annotations | `zsh Tests/attachment-annotations.sh` | Native Quick Look annotation flow in an isolated sandboxed fixture; see [capture limits](attachment-annotations.md) |
| Chat input | `zsh Tests/scrollable-composer.sh` | Cursor visibility beyond six lines, scrolling, wrapping, resize, IME, undo and paste |
| Transcript layout | `swift test --disable-sandbox --filter TranscriptLayoutTests` | Real thumbnail loading, annotation height stability, cached previews, legacy notes, scrolling during incoming replies, composer growth, resizing and full-chat navigation |
| Transcript restoration | `zsh Tests/transcript-startup.sh` | Delayed loading, persisted reading position, changed-width relaunch and rapid chat switching |
| Transcript resize | `zsh Tests/transcript-resize.sh` | Reading-message anchoring, width/height reflow, incoming messages and follow-latest |
| Sheets | `zsh Tests/sheet-sizing.sh` | Growing/shrinking content and group member selection |
| Backgrounds | `zsh Tests/animated-backgrounds.sh` | Import, playback, and Reduce Motion |
| Voice | `zsh Tests/voice-recording.sh` | Audio conversion, waveform, and restored drafts |
| Voice composer | `zsh Tests/voice-composer.sh` | Return/Escape behavior |
| Voice shortcut | `zsh Tests/voice-shortcut.sh` | ⌘⇧D menu dispatch, recording states, chat/window routing and key repeat |
| Voice sandbox | `zsh Tests/voice-sandbox.sh` | Synthetic speech in a signed sandbox |
| Tools | `zsh Tests/mcp-fixture.sh --check` | Signed CLI and broker with disposable data |
| Muse runtime | `zsh Tests/muse-runtime.sh` | Session recovery and failure handling |
| Message delivery | `zsh Tests/message-delivery.sh` | All five adapters, active-turn delivery, classification fallback and timing races |
| Delivery classifier | `zsh Tests/message-delivery.sh --classify` | Synthetic urgency examples using Apple Intelligence in a signed sandbox; skips when unavailable |

Real microphone recording, live provider sign-in, and model calls need separate
manual checks. For bundle boundaries, use `scripts/verify-agent-host.sh` and
`scripts/verify-updater.sh` on the built app; the smoke suite runs these too.

Use `zsh Tests/scrollable-composer.sh --benchmark` for repeatable edit and height
measurement timings on short and long drafts. These timings exclude display
latency and are informational rather than pass/fail thresholds.

For annotation checks without taking desktop focus, use
`zsh Tests/attachment-annotations.sh --headless`; add `--render-previews` for
saved preview images. The foreground fixture moves the pointer and takes focus.
Use `--cursor-check` for selection cursors, `--visual-cancellation` for recorded
save/cancel behavior, or `--preview` to leave an annotation open for inspection.
`--build-only` prepares the fixture without launching it.

Use `swift test --disable-sandbox --filter KeyboardShortcutsTests` for shortcut
configuration. For annotation storage and delivery:

```sh
swift test --disable-sandbox --filter 'AttachmentAnnotationTests|MessengerDocumentationTests|ConversationDraftsTests'
```

## Scenarios

A scenario opens the real app in a prepared state for screenshots: bots, conversations,
attachments, wallpapers and statuses, with scripted bots in place of harnesses. Each one
is a folder in `Scenarios/`; [its README](../Scenarios/README.md) describes the format.

```sh
zsh scripts/scenario.sh                      # open the picker
zsh scripts/scenario.sh family-butler        # open one scenario
zsh scripts/scenario.sh --shots family-butler # play it and save its shots
zsh scripts/scenario.sh --shots --all
```

The script derives `.build/Noodle Scenarios.app` from the development build. That bundle
has its own identifier, container and preferences, may read `Scenarios/`, and has no
network, account, group or helper entitlement; every launch starts from an empty
workspace. The loader is compiled only under `NOODLE_DEV_HOOKS` and runs only in that
bundle, so it never touches the data of another Noodle.

Once the bundle is open, the Scenarios menu switches scenario, reloads the current one
after an edit to its files, and advances a timeline that waits for a key (Next Step).
Launched with a name, the terminal stays attached and Return does the same. `--shots`
saves each `capture` step to `Scenarios/NAME/shots/`, which Git ignores; it runs from a
terminal with Screen Recording permission. `--no-build` reuses the development build
already in `.build`, `--debug` builds the debug configuration, and `--shadow` keeps the
window shadow.

`swift test --disable-sandbox --filter ScenarioTests` loads, seeds and plays every folder
in `Scenarios/` without opening a window.

## Build and test local models

The MLX Foundation Models adapter is pinned to an upstream revision because its
macOS 27 integration is not yet tagged. See `Package.swift` and `Package.resolved`.
The new APIs are guarded by the Foundation Models module version and runtime OS
availability, preserving builds with the older SDK. Use Xcode 27 and install its
Metal Toolchain component for a build with local model support. Model resources
and their licenses are supplied by the person importing them; weights are not
distributed with Noodle. `scripts/build-app.sh` uses `scripts/swift-apple.sh`,
which can select the installed macOS 27 Command Line Tools when Xcode's SDK is
older. It does not change `xcode-select`. Use the same wrapper for `build`, `test`,
and `run`, or override `NOODLE_SWIFT` and `NOODLE_MACOS_SDK` explicitly.
With mixed installations, the wrapper builds and tests the Apple helper and core
targets; app packaging separately builds SwiftUI with the matching full Xcode SDK.
The newer helper uses `.build/apple27` so ordinary app builds cannot replace it.
For local-model tests against an unbundled helper, run
`zsh scripts/build-mlx-metal.sh "$(zsh scripts/swift-apple.sh build --show-bin-path)"`
first. App packaging builds and includes these shaders automatically.

Ordinary tests use synthetic model folders. Set `NOODLE_TEST_APPLE_MODEL=1` to
run the live Apple tests. Set `NOODLE_TEST_MLX_MODEL` to an existing model folder
to run the sandboxed local-model test. `NOODLE_APPLE_TEST_HELPER` selects a bundled
helper for testing its packaged resources. These tests use disposable bot storage.

CI keeps the normal suites on `macos-26` and probes `macos-latest` for optional
macOS 27 harness tests. `scripts/detect-apple27.py` checks the OS, Apple Silicon,
and an installed SDK/compiler with full Xcode's XCTest support. When prerequisites
are missing, the job summary reports a skip before any model build or Metal
download. When they are present, CI builds the isolated helper and Metal shaders,
asserts that local-model support was compiled in, and runs the regression suite.
Build or test failures block Noodle release preparation; missing prerequisites do
not. Live inference remains opt-in because hosted runners need not have Apple
Intelligence enabled or model weights installed. This optional test job does not
change the SDK used to package releases.

## Runtime logs

In Console, filter by `com.pdparchitect.noodle.runtime`, or run:

```sh
log stream --style compact --level debug --predicate 'subsystem == "com.pdparchitect.noodle.runtime"'
```

Logs include bot/wake IDs, lifecycle events, and inbox counts, without message
contents or credentials. `wake-submitted` means dispatched; `inbox-read` means
Messenger consumed the inbox. A completed turn does not prove the user's task
succeeded. Correlation is best effort, and macOS controls retention.

Development hooks, such as the integration fixtures and the switch below, are
compiled into Noodle Dev and debug builds only. A release has none, and
`scripts/verify-launch-hooks.sh` fails packaging if one is found. To start Noodle
Dev with harness detection disabled:

```sh
scripts/build-app.sh
NOODLE_SIMULATE_NO_HARNESSES=1 '.build/Noodle Dev.app/Contents/MacOS/Noodle'
```

**Check Installation** then discovers external CLI installs for that session,
excluding app-bundled copies. Relaunch without the flag to restore normal detection.

[Releases](releases.md) · [Documentation](README.md)
