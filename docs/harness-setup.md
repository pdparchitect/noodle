# Harness setup

A harness is the agent program Noodle runs for each bot. Noodle supports Codex,
Claude Code, Vercel FX, Grok Build, and Muse Code, using your existing account,
plus the experimental bundled Apple harness using Apple Intelligence on device.

1. Open **Settings → Harness**.
2. Choose **Install…** beside your provider and run the displayed command in Terminal.
3. Return to Noodle and choose **Check Installation**.
4. Sign in using the option below, then choose **Check Again**.

| Harness | Sign in |
| --- | --- |
| Codex | **Sign In…** in Noodle, or `codex login` in Terminal |
| Claude Code | **Sign In…** in Noodle, or `claude auth login` in Terminal |
| FX | **Sign In…** in Noodle, or `fx login` in Terminal |
| Grok Build | `grok login` in Terminal |
| Muse Code | `muse login` in Terminal |

Once a harness is detected, create a bot and select its model and, where available,
reasoning effort. Codex, FX, Grok Build, and Apple support restricted access.
Claude Code and Muse Code require [autonomous access](security.md).

## If setup fails

- **Not installed:** use the installer shown in Noodle. Noodle checks supported native installations; an arbitrary shell wrapper may not work.
- **Codex browser sign-in fails:** run `codex login` in Terminal if your account does not allow device-code login.
- **Sign-in status unknown:** check the harness in Terminal, then choose **Check Again**. Unknown does not mean signed out.
- **Update required:** follow the update instructions in Settings and recheck. Noodle does not install harness updates itself.
- **Bot fails to start:** resolve the reported installation, account, or service error, then use **Settings → Security → Retry Startup**.

FX is experimental. Restricted startup and authenticated network requests are
verified, but the latest full Messenger test was blocked by Vercel's HTTP 429
free-tier model rate limit. Grok Build passed restricted Messenger replies and
session resume. Provider usage limits still apply in either access mode.

[Documentation](README.md)
