# Build and test

Run commands from the repository root. You need macOS 15 or later and full Xcode.
For Noodle Computer, see its [development guide](../Computer/DEVELOPMENT.md).

```sh
scripts/build-and-launch.sh
Tests/smoke-test.sh
```

The build creates `.build/Noodle Local.app` with separate development data. The
smoke suite runs tests and verifies the signed app and helpers. To install the
local app in Applications and register its Shortcuts action:

```sh
scripts/install-app.sh
```

The build uses an installed Apple Development identity. Override it with
`NOODLE_SIGNING_IDENTITY`; `-` selects ad-hoc signing.

## Test with production data

Quit the installed Noodle app first, then run:

```sh
scripts/build-and-launch.sh --production-data
```

This creates `.build/Noodle.app` using the released app's data. Never run both
copies together: they would manage the same bots and conversations.

## Documentation changes

Message/event guidance, the Messenger skill, and CLI help come from
[`MessengerDocumentation.swift`](../Sources/NoodleCore/MessengerDocumentation.swift).
After editing it, regenerate the reference and run its tests:

```sh
swift run --disable-sandbox NoodleDocumentation --write docs/message-reference.md
swift test --disable-sandbox --filter MessengerDocumentationTests
```

Commit the generated file with the source. Builds check for drift. Keep every
event's recipients, fields, and handling guidance; update encoding-coverage tests
when payload fields change.

For reader-facing docs, lead with the task and steps. Keep protocol details in
references, link to existing explanations, and omit implementation history and old
test reports. Add user-visible changes to the appropriate Unreleased changelog.

## Coverage

Run the Swift suite with coverage and generate a source-only report:

```sh
swift test --disable-sandbox --enable-code-coverage
python3 scripts/coverage-report.py \
  --input "$(swift test --disable-sandbox --show-codecov-path)" \
  --output .build/coverage/noodle
```

Open `.build/coverage/noodle/summary.md` for module totals and the largest gaps.
The directory also contains a complete file summary and the original SwiftPM
JSON export. To compare against a saved report, pass
`--baseline /path/to/previous/summary.json`; changes are percentage points.

Each Noodle CI test job, including pull requests, publishes the summary and a
`noodle-coverage` artifact retained for 30 days. Coverage counts root source
modules linked into the test bundle, including app code pulled in by integration
tests, and excludes test code and dependencies. Separate native fixtures do not
contribute to that report.
Reporting does not impose a minimum percentage; test failures still fail CI.

Grok and Muse inspection regression tests run in the default Swift suite using
temporary local stdio fixtures and isolated home directories. They exercise
handshakes, invalid replies, timeouts, and process cleanup without installed
harnesses, authentication, or network requests. Live harness probes remain
explicitly opt-in and are not required by release CI.

## Focused checks

Run native UI fixtures from a logged-in Mac. They use isolated test data.

| Area | Command | Check |
| --- | --- | --- |
| Chat | `zsh Tests/chat-features.sh` | Name menu, profiles, Markdown, draft and keyboard behavior |
| Chat input | `zsh Tests/scrollable-composer.sh` | Cursor visibility beyond six lines, scrolling, wrapping, resize, IME, undo and paste |
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

## Runtime logs

In Console, filter by `com.pdparchitect.noodle.runtime`, or run:

```sh
log stream --style compact --level debug --predicate 'subsystem == "com.pdparchitect.noodle.runtime"'
```

Logs include bot/wake IDs, lifecycle events, and inbox counts, without message
contents or credentials. `wake-submitted` means dispatched; `inbox-read` means
Messenger consumed the inbox. A completed turn does not prove the user's task
succeeded. Correlation is best effort, and macOS controls retention.

For a debug build with harness detection disabled at startup:

```sh
NOODLE_BUILD_CONFIGURATION=debug scripts/build-app.sh
NOODLE_SIMULATE_NO_HARNESSES=1 '.build/Noodle Local.app/Contents/MacOS/Noodle'
```

**Check Installation** then discovers external CLI installs for that session,
excluding app-bundled copies. Relaunch without the flag to restore normal detection.

[Releases](releases.md) · [Documentation](README.md)
