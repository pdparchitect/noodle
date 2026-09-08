# Development

Run the commands below from the repository root.

## Build, launch, and test

Requirements: macOS 15 or later and full Xcode.

```sh
scripts/build-and-launch.sh
Tests/smoke-test.sh
```

Local builds use the isolated development container by default and are written to `.build/Noodle Local.app`. This keeps test bots, conversations, preferences, and agent state separate from the released app. To install that development build in `/Applications` and register its App Intent:

```sh
scripts/install-app.sh
```

To test current local code against the released app's production data, first quit the installed Noodle app, then use the explicit production-data mode:

```sh
scripts/build-and-launch.sh --production-data
```

That mode writes `.build/Noodle.app` with the production bundle identity. Never run it at the same time as `/Applications/Noodle.app`; both processes would own the same conversations and agent state. Release packaging selects the production identity automatically.

The build automatically uses the first installed Apple Development identity so macOS can index App Intents. Set `NOODLE_SIGNING_IDENTITY` to override that choice, or set it to `-` explicitly for an ad-hoc build.

For native sheet sizing changes, run `zsh Tests/sheet-sizing.sh` from a logged-in macOS desktop. This standalone UI regression fixture exercises the shared sheet sizing and real member picker with synthetic bots: repeated growth/shrinkage, 11 → 1 → 11 members, a large scrollable group and an empty group. It opens no Noodle store or agent runtime and does not modify saved groups. Keep it separate from headless tests.

## Chat interaction checks

For profiles, verify clicking the dimmed parent window dismisses without activating the control behind it; clicks inside remain interactive, and switching apps dismisses too. Repeat opening/closing to catch stale event monitors. Verify the name menu crops uploaded portrait avatars to circles, including non-square images.

The fixture checks menu title formatting, description truncation and circular image transparency at startup. Its description toggle uses the fixture's isolated preferences; check the toggle defaults off and survives reopening. In Noodle, the same toggle lives in General settings. Menu selection must insert only the name, even with descriptions enabled.

Run `zsh Tests/chat-features.sh` on a logged-in Mac to open an isolated, sandboxed UI fixture. It uses synthetic bots and cannot send messages or load the app's data. Verify `@` opens a real macOS menu above the symbol; native type-to-select and Up/Down navigation; Return and mouse selection inserting plain names without incrementing the submission counter; Escape dismissal; normal typing and undo; and profile Reply/Direct Message actions preserving the draft and returning keyboard focus. Menu materials, row spacing and highlighting must be system-rendered, with no custom row views. The profile must contain only the public description, never a backstory. Close the fixture before rebuilding it.

## Message documentation

Message and event guidance lives in `Sources/NoodleCore/MessengerDocumentation.swift`, alongside exhaustive references for runtime wake reasons, delivery kinds, group notices, effects and CLI commands. The Messenger skill and CLI help use this catalogue directly. Bot workspace and Codex runtime instructions contain only a short pointer requiring the skill to be read before handling messages or wake events, rather than repeating the full guide. Workspace synchronization refreshes the managed guidance while preserving each bot's backstory and custom skills.

After changing the catalogue, regenerate and commit the reference:

```sh
swift run --disable-sandbox NoodleDocumentation --write docs/message-reference.md
swift run --disable-sandbox NoodleDocumentation --check docs/message-reference.md
```

The application build checks the reference without rewriting it. Tests also check documentation freshness and encoded delivery/message field coverage. The generator runs locally and is not bundled into the app.

## Runtime diagnostics

Debug and release builds emit lightweight macOS unified logs under subsystem `com.pdparchitect.noodle.runtime`, category `lifecycle`. Filter by that subsystem in Console, or stream them while reproducing a problem:

```sh
log stream --style compact --level debug --predicate 'subsystem == "com.pdparchitect.noodle.runtime"'
```

For retained records, use:

```sh
log show --last 1h --style compact --predicate 'subsystem == "com.pdparchitect.noodle.runtime"'
```

Lifecycle records include the bot UUID, harness, wake UUID/reason, event and delivery count—not bot names, message contents, prompts, commands, file paths, credentials or raw error text. macOS controls log retention; this is diagnostic evidence, not a durable audit trail. Debug builds additionally log queued/coalesced inbox notifications and non-consuming inbox inspections. They do not log every streamed token or polling tick.

Interpret the events literally:

- `wake-prepared` / `wake-submitted`: Noodle prepared the turn and handed its request to the transport, not proof the harness ran it.
- `turn-accepted`: Codex acknowledged the turn-start request. Claude has no equivalent acknowledgement; `turn-output-observed` means its first assistant/result event arrived.
- `inbox-read`: Messenger fetched and consumed the inbox; `count` is the total deliveries (including reaction changes) and `reads` is the number of successful consuming calls in this wake. Zero deliveries with a positive read count is a successful empty check. `--peek` is debug-only and does not count as consumption. `inbox-read-failed` reports the number of failed fetches in `reads`.
- `turn-completed`, `turn-failed`, `turn-interrupted`, `turn-ended-unknown`: harness-reported termination of the turn, not evidence the user's task was accomplished.
- `runtime-starting`, `runtime-stopped`, `runtime-disconnected`, `runtime-failed`: runtime lifecycle, including failures before a wake exists.

For cross-process correlation, `.noodle/runtime-log-context.json` holds only the active wake's IDs, harness and reason. It is replaced at the next wake and cleared on normal completion, failure, stop or runtime startup. Sandboxed commands can be unable to contact macOS's logging service even when Messenger succeeds. During an active wake, Messenger therefore updates a small bounded metadata receipt in `.noodle/runtime-log-inbox.json`; Noodle relays its read/failure counts to unified logging before the terminal lifecycle record, then removes it. The log timestamp is the relay time, not the exact time of each read. A receipt left by an abrupt app exit is relayed at the next runtime startup when its matching context is still available.

The receipt contains only IDs, harness, wake reason and counts, and uses a non-blocking lock (`.noodle/runtime-log-inbox.lock`). No message bodies or raw errors cross this diagnostic path. It never drives scheduling, inbox state or recovery; missing permissions, lock contention or other logging failures do not block work. CLI calls outside an active wake attempt direct logging as `uncorrelated`, which may still be unavailable under a restricted harness. Correlation is best effort: a child command that outlives its turn cannot be reliably attributed this way. Existing bots need the updated app/runtime; no agent reporting commands or new behavioural rules are required.

## Development-only Settings

Settings includes a Dev tab in debug builds only. The whole tab is compiled out of release builds. To build with development tools enabled:

```sh
NOODLE_BUILD_CONFIGURATION=debug scripts/build-app.sh
```

The Dev tab contains **Test Autonomous Runtime**, a fixed isolation-compatibility probe. It does not start a bot or prove browser access. See [Security and agent access](security.md) for the helper boundary and verification checks.

To test the normal app with no detected harnesses, quit Noodle and launch a debug build with:

```sh
NOODLE_SIMULATE_NO_HARNESSES=1 '.build/Noodle Local.app/Contents/MacOS/Noodle'
```

This only overrides harness detection, including subsequent refreshes. Check Installation enables external standalone/CLI detection for the current session; ChatGPT/Codex app-bundled binaries stay excluded. It adds no UI and does not remove installed binaries, credentials, bots, or conversations. Relaunch without the variable to restore normal detection. The override is compiled out of release builds; they ignore the variable.

For distribution builds and GitHub Actions configuration, see [Releases and updates](releases.md).


---

[Documentation](README.md) · [Noodle](../README.md)
