# Harness setup

**Settings → Harnesses** lists all supported providers, including those not installed. Noodle has native drivers for Codex, Claude Code, and Vercel FX. **New Bot** is disabled in the toolbar and File menu (including Command-N) until a harness is detected. The save action checks the selected harness again before creating anything.

## Install

Choose **Install…** for provider-specific installation instructions. For Codex, copy OpenAI's official command, open Terminal, paste it and run it:

```sh
curl -fsSL https://chatgpt.com/codex/install.sh | sh
```

Return to Noodle and choose **Check Installation**. This is a guided external installation, not a background installer: Noodle does not execute the script, download executable code, request administrator privileges, or change shell profiles itself. The official script manages its own package, prompts, and PATH configuration. [Official instructions](https://learn.chatgpt.com/docs/codex/cli).

Codex defaults to `~/.local/bin/codex`, linked to its package under `~/.codex/packages/standalone/current`. This is an installation for the current Mac user, available outside Noodle—not an all-users installation. `CODEX_INSTALL_DIR` can change the command location; other harness providers can supply their own system-wide installer instructions. Noodle also detects `/usr/local/bin/codex`, `/opt/homebrew/bin/codex`, and the ChatGPT/Codex app-bundled binaries. It prefers the standalone package when present and accesses it through its existing narrow `~/.codex` permission.

For Claude Code, Noodle supports Anthropic's native installer:

```sh
curl -fsSL https://claude.ai/install.sh | bash
```

The installer creates `~/.local/bin/claude`, linked to a signed version under `~/.local/share/claude/versions`. Return to Noodle and choose **Check Installation**. Noodle does not run the installer itself. [Official Claude Code quickstart](https://code.claude.com/docs/en/quickstart).

## Account status and sign-in

For FX, install the signed native binary at `~/.local/bin/fx` using the official command:

```sh
curl -fsSL https://fx.sh/setup.sh | bash
```

Return to Noodle and check the installation. **Sign In…** starts FX's Vercel device-code flow; the app displays only the verified Vercel URL and one-time code. Existing `fx login`, `fx login codex`, and `fx login grok` accounts are used as configured in FX. The isolated Agent Host reads `fx status --json` and `fx models --json`, returning only account availability and model metadata. Models come from the installed FX provider's live catalogue, not a hard-coded list. No FX credential files are exposed to Noodle. FX's model default is respected when no model is selected; unsupported effort controls are not invented.

FX uses its native ACP v1 stdio server (`fx acp`), with saved session IDs, Messenger-based replies, inbox/heartbeat/recovery events, and durable unfinished-turn recovery. FX reads the workspace's `AGENTS.md` and shared `.agents/skills`; no global instruction or skill directories are modified. Autonomous access is currently required, as for Claude Code. A new restricted FX bot remains stopped until the user enables it in Security. ACP permission requests are accepted only for the current session using the offered **allow once** choice; unsupported client methods fail closed. See the [official FX documentation](https://fx.sh/docs) and [source protocol](https://github.com/vercel-labs/fx/tree/main/src/acp). The adapter was checked against FX 0.0.8; FX is experimental upstream.

Installed providers are checked asynchronously through the provider's setup interface. For Codex, Noodle asks app-server for `account/read` metadata with `refreshToken: false`. It does not read, copy, log, or parse credential files or API keys. **Signed in** means Codex reports a stored account, not that Noodle has validated a model request or remaining credits. Refresh retains the last result; a progress spinner appears only for checks exceeding 300 milliseconds. Timeouts and process failures show an error rather than claiming the user is signed out.

**Sign In…** starts Codex's device-code flow. Copy the code, open the sign-in page, and finish in your browser. Device-code login must be enabled in your ChatGPT account or workspace settings. Noodle rechecks the account after completion. Cancel, closing Settings, and timeout stop the setup process. No agent thread or model turn is created.

If device-code login is unavailable, run `codex login` in Terminal and then **Check Again**. [Authentication documentation](https://learn.chatgpt.com/docs/auth).

For Claude Code, the isolated Agent Host asks the signed CLI for `claude auth status --json` and returns only the resulting signed-in state. **Sign In…** starts Anthropic's browser sign-in through that same fixed command. Noodle never reads or receives Claude's configuration, account details, or credentials. You can alternatively run `claude auth login` in Terminal and choose **Check Again**.

Claude bots use a persistent stream-json session with the selected model and supported effort level. Noodle offers the standard Fable, Opus, Sonnet, and Haiku aliases; Claude Code resolves each alias to the appropriate current model for the signed-in account. Claude bots currently require autonomous access; restricted mode remains available for Codex bots.

Noodle saves a new Claude session pointer only after Claude confirms initialization. If resuming explicitly fails because that exact session does not exist, Noodle clears only its stale pointer and lets supervision start a fresh session. Bot workspaces, memory, conversation history and Claude transcripts are untouched. Authentication, model, quota and transport errors do not discard valid session pointers.

## Development and security

FX verification note: an opt-in live test with FX 0.0.8 confirmed the signed-in account, model catalogue, session creation, Messenger skill discovery, and attempted shell execution. FX's own safety review returned `tool_review_held` / `review_unavailable` / `transport_permanent`, preventing the Messenger command from running. Full chat round-trip and resumed replies remain unverified until that upstream review service is available. Noodle reports the held execution as a failed runtime and preserves unfinished work; it does not bypass review. Use **Retry Startup** after resolving FX's service issue. The opt-in test is `FxLiveTests`, with `NOODLE_TEST_FX_EXECUTABLE` and `NOODLE_TEST_MESSENGER_EXECUTABLE` pointing at the installed FX and built Messenger executables.

Bot workspace bootstrap runs on creation, application startup/reload, and saving bot settings, before the corresponding runtime launch. It does not rerun for a standalone runtime restart or crash-recovery retry. Bootstrap maintains `CLAUDE.md → AGENTS.md` and the workspace-local `.claude/skills → ../.agents/skills` link so Claude can discover the same skills natively. An existing native `.claude/skills` directory is preserved and receives only missing per-skill links; conflicting native skills and redirected Claude directories are left untouched. This never modifies the user's global `~/.claude` directory. Existing bots receive these links on the next app launch; shared skill content is not copied.

`NOODLE_SIMULATE_NO_HARNESSES=1` hides all harnesses at startup in debug builds. **Check Installation** then enables discovery of external standalone/CLI installations for that session; app-bundled ChatGPT/Codex copies stay excluded. If no external installation exists, the UI remains uninstalled and bot creation remains disabled. A new flagged launch resets the simulation; release builds ignore the flag.

The app does not strip quarantine, add executable-write permission, or introduce an installation helper. It has read-only access to the exact paths needed to discover the Claude installer link, its versioned binary, and `~/.local/bin/fx`; it has no access to `~/.claude` or `~/.fx`. New agents default to restricted access, and existing agents retain their settings. The existing host accepts only fixed external command locations and verifies the exact OpenAI, Anthropic, or Vercel signing identity before launch.

Tests exercise account states, sign-in completion/cancellation, external discovery, and rejection of arbitrary or unsigned autonomous executables. Optional fixtures `NOODLE_TEST_CODEX_EXECUTABLE`, `NOODLE_TEST_INSTALLED_HOME`, and `NOODLE_TEST_CLAUDE_EXECUTABLE` verify real signed installations without changing production data.
