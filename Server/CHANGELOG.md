# Changelog

## [Unreleased]

### Added

- Noodle Server runs on Windows 10 and 11, on arm64 or x86_64: download the ZIP, then run `noodled check`, `noodled login` and `noodled run` in PowerShell. Each bot works in a sandbox that keeps it out of your files and the server's data, and whatever it started ends with it; unlike on Linux and a Mac, bots are not yet kept apart from each other. The server keeps its file and data in `%LOCALAPPDATA%\Noodle Server`.
- Noodle Server runs on a Mac with Apple silicon: download the ZIP, then run `noodled check`, `noodled login` and `noodled run` in Terminal. Each bot works in a sandbox of its own, as on Linux, and whatever it started ends with it. The server keeps its file and data in `~/Library/Application Support/Noodle Server`.
- Old bot sessions are cleaned up: once a day, the server deletes the Claude Code, Codex, Grok Build, FX, OpenCode and Devin sessions a bot has not used for a week, keeping the one it is in, and gives the space back to the disk; sessions left behind by a harness the bot used before go too. Codex, OpenCode and Devin delete their own, started briefly when nothing is running; Codex history they cannot delete goes once untouched for a week. A bot's own files are never touched.
- The daily cleanup also deletes the temporary files a bot's harness and the bot itself leave behind, once nothing has touched them for a week.

### Changed

- Claude Code bots no longer sync the skills and plugins enabled on the claude.ai account, which are for the account's own Claude sessions and include browser and computer skills for tools a bot does not have, and the copies already in each bot are removed.
- Codex bots no longer download OpenAI's plugin catalog or the plugins installed on the ChatGPT account, which are made for ChatGPT and which no bot used, and the copies already in each bot, tens of megabytes apiece, are removed.
- Noodle's source is now under the Functional Source License instead of Apache 2.0: free to use, read and change for anything except a competing product, and each version becomes Apache 2.0 two years after its release. Earlier versions stay under Apache 2.0.

### Fixed

- Bots run and answer: the server starts them when it starts and as soon as they are made, and gives each the messenger it reads and sends messages with. Until now they stayed offline and never answered.

## [0.5.0] - 2026-11-26

### Changed

- Claude Code and Codex run with their usage and error reports turned off.

### Fixed

- A bot moved to another harness no longer resumes an old session it had there, which missed everything since. It starts fresh and its next turn catches up from the conversation and workspace, carrying on with unfinished work.

## [0.4.0] - 2026-11-25

### Changed

- A bot's held call now says so in its result's `_meta["noodle/approval"]`, as `{ id, state }`, instead of in `structuredContent`, so a script can tell it from a service's answer; no tool can set that key, so a result carrying it never reached the service.

## [0.3.0] - 2026-11-22

### Added

- Approvals: a bot's call to a tool its service marks destructive waits on the server for its owner, who approves or declines it from Noodle on their Mac or phone; an approved one runs once, and the bot is told the outcome.

## [0.2.0] - 2026-11-21

### Changed

- Removing a tool revokes its sign-in at the service, where the service allows it, before forgetting it here, as Noodle does.

### Fixed

- Saved tools that cannot be read are no longer replaced when a tool is added or changed: the server refuses changes until the file is restored.

## [0.1.0] - 2026-11-11

### Added

- `sudo noodled setup` sets up a server step by step: it checks the machine and offers to install bubblewrap, msquic, Claude Code and Codex, asks a few questions, writes the configuration or keeps the one there, installs the service, signs in, starts the server and prints an invitation for your first device.
- Noodle Server, `noodled`: a Noodle Hub for Linux, set up in one file, that runs bots for the people you list on the Claude Code and Codex you install, each bot in a sandbox of its own.
- Plans say which harnesses, profiles and models people may use and how many tokens; users are listed by name with their plan.
- `noodled invite <user>` prints a link that pairs one device, and with `--qr` or `--png` its QR code too.
- `noodled login claude-code` and `noodled login codex` sign the server in with the harness's own sign-in, for a harness or one of its profiles; `noodled check` lists the logins nobody has signed in to yet.
- Download for Linux on arm64 and x86_64, with a systemd service.
