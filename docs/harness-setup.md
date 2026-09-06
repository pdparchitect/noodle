# Harness setup

**Settings → Harnesses** lists all supported providers, including those not installed. Codex is currently supported. **New Bot** is disabled in the toolbar and File menu (including Command-N) until a harness is detected. The save action checks the selected harness again before creating anything.

## Install

Choose **Install…** for provider-specific installation instructions. For Codex, copy OpenAI's official command, open Terminal, paste it and run it:

```sh
curl -fsSL https://chatgpt.com/codex/install.sh | sh
```

Return to Noodle and choose **Check Installation**. This is a guided external installation, not a background installer: Noodle does not execute the script, download executable code, request administrator privileges, or change shell profiles itself. The official script manages its own package, prompts, and PATH configuration. [Official instructions](https://learn.chatgpt.com/docs/codex/cli).

Codex defaults to `~/.local/bin/codex`, linked to its package under `~/.codex/packages/standalone/current`. This is an installation for the current Mac user, available outside Noodle—not an all-users installation. `CODEX_INSTALL_DIR` can change the command location; other harness providers can supply their own system-wide installer instructions. Noodle also detects `/usr/local/bin/codex`, `/opt/homebrew/bin/codex`, and the ChatGPT/Codex app-bundled binaries. It prefers the standalone package when present and accesses it through its existing narrow `~/.codex` permission.

## Account status and sign-in

Installed providers are checked asynchronously through the provider's setup interface. For Codex, Noodle asks app-server for `account/read` metadata with `refreshToken: false`. It does not read, copy, log, or parse credential files or API keys. **Signed in** means Codex reports a stored account, not that Noodle has validated a model request or remaining credits. Refresh retains the last result; a progress spinner appears only for checks exceeding 300 milliseconds. Timeouts and process failures show an error rather than claiming the user is signed out.

**Sign In…** starts Codex's device-code flow. Copy the code, open the sign-in page, and finish in your browser. Device-code login must be enabled in your ChatGPT account or workspace settings. Noodle rechecks the account after completion. Cancel, closing Settings, and timeout stop the setup process. No agent thread or model turn is created.

If device-code login is unavailable, run `codex login` in Terminal and then **Check Again**. [Authentication documentation](https://learn.chatgpt.com/docs/auth).

## Development and security

`NOODLE_SIMULATE_NO_HARNESSES=1` hides all harnesses at startup in debug builds. **Check Installation** then enables discovery of external standalone/CLI installations for that session; app-bundled ChatGPT/Codex copies stay excluded. If no external installation exists, the UI remains uninstalled and bot creation remains disabled. A new flagged launch resets the simulation; release builds ignore the flag.

The original six entitlements are unchanged. The app does not strip quarantine, add executable-write permission, or introduce an installation helper. Restricted agents inherit the app sandbox. Extended access remains per-bot opt-in; the existing host accepts only fixed external command locations, resolves the official installer symlinks, and verifies OpenAI signatures on Codex and its supporting executables before launch.

Tests exercise account states, sign-in completion/cancellation, external discovery, and rejection of arbitrary/unsigned extended executables. Optional fixtures `NOODLE_TEST_CODEX_EXECUTABLE` and `NOODLE_TEST_INSTALLED_HOME` test real account RPC and an isolated official-script installation without changing production data.
