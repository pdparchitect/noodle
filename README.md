<div align="center">

<img src="Support/AppIcon.png" alt="Noodle" width="88">

# Noodle

**A workspace for you and your AI agents.**

<p>
  <img alt="macOS 26+" src="https://img.shields.io/badge/macOS-%E2%89%A526-0a0a0a?style=flat-square&logo=apple&logoColor=white">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-0a0a0a?style=flat-square&logo=swift&logoColor=white">
  <img alt="Persistent agents" src="https://img.shields.io/badge/agents-persistent-0a0a0a?style=flat-square">
  <img alt="Individual and team work" src="https://img.shields.io/badge/work-individual%20%2B%20teams-0a0a0a?style=flat-square">
</p>

[Website](https://pdparchitect.github.io/noodle/) · [Download](#download) · [Documentation](docs/README.md) · [Enterprise](docs/enterprise.md) · [Security](docs/security.md)

</div>

<p align="center">
  <img width="2914" height="2186" alt="image" src="https://github.com/user-attachments/assets/e98867e0-85bf-4497-b346-99e0f59786bc" />
</p>

<p align="center">
  <img width="32%" alt="Noodle screenshot 1" src="https://github.com/user-attachments/assets/cc993ca9-0ab2-4939-9a40-1edc9c7843d1" />
  <img width="32%" alt="Noodle screenshot 2" src="https://github.com/user-attachments/assets/1abafd1e-a02b-41c1-82c1-7937a5dd8be2" />
  <img width="32%" alt="Noodle screenshot 3" src="https://github.com/user-attachments/assets/064f4498-1110-4e39-9d0d-171a700aaab7" />
</p>

Give an agent a task, or bring several into a group to work toward a shared goal.
Each agent keeps its own workspace and backstory.

Agents run on the [harness](docs/harness-setup.md) you choose, using your existing account:

<p>
  <img alt="Codex" src="https://img.shields.io/badge/Codex-10a37f?style=flat-square">
  <img alt="Claude Code" src="https://img.shields.io/badge/Claude%20Code-d97757?style=flat-square">
  <img alt="FX" src="https://img.shields.io/badge/FX-0a0a0a?style=flat-square">
  <img alt="Grok Build" src="https://img.shields.io/badge/Grok%20Build-e11d48?style=flat-square">
  <img alt="Muse Code" src="https://img.shields.io/badge/Muse%20Code-0866ff?style=flat-square">
  <img alt="OpenCode v2" src="https://img.shields.io/badge/OpenCode%20v2-eab308?style=flat-square">
  <img alt="Antigravity" src="https://img.shields.io/badge/Antigravity-4285f4?style=flat-square">
  <img alt="Apple Intelligence, on device" src="https://img.shields.io/badge/Apple%20Intelligence-on%20device-a855f7?style=flat-square">
</p>

## Download

| App | What it does | Minimum macOS |
| --- | --- | --- |
| **[Noodle Suite](https://github.com/pdparchitect/noodle/releases/tag/suite-latest)** | Noodle and its released companion apps in one installer. Each app updates independently. | 26 |
| **[Noodle](https://github.com/pdparchitect/noodle/releases/latest)** | Work with agents individually or as a team. | 15 |
| **[Noodle Computer](https://github.com/pdparchitect/noodle/releases/tag/computer-latest)** | Linux and macOS computers for you and your agents. | 26 |
| **[Noodle Applet](https://github.com/pdparchitect/noodle/releases/tag/applet-latest)** | Run tools, websites, experiments, and games created by you and your agents. | 15 |
| **[Noodle Browser](https://github.com/pdparchitect/noodle/releases/tag/browser-latest)** | Dedicated browsers you sign in to and assign to agents, with persistent profiles, tabs, history, bookmarks, and file transfers. | 26 |

Download the DMG, open it, and drag the app to **Applications**. ZIP downloads are also available.
Noodle Computer, Noodle Applet, and Noodle Browser are optional companions and also work on their own.

## Get started

1. Open Noodle and follow **Settings → Harness** to install and sign in.
2. Create a bot, choose its harness, and describe its role in the backstory.
3. Give it a task and the files or context it needs. For a shared goal, create a group and add the agents you want working together.

All harnesses start with restricted access. Optional
unrestricted access can reach files and services beyond the bot's workspace. See
[how the sandbox works, its strengths, and its limitations](docs/security.md).

To give a bot a computer, create a Shell or Desktop in Noodle Computer, then add it
in the bot's **Computers** tab. Several bots can share the same computer.

To give a bot a browser, create one in Noodle Browser and sign in to the sites it
needs. Add it in the bot's **Browsers** tab. The agent uses those same signed-in
pages in the background and can send clickable previews back to your conversation.
Each browser keeps its own sign-ins and browsing data.

## Features

- **Persistent agents** with their own workspace, backstory, and history.
- **Teams** of bots working toward a shared goal.
- **Restricted by default**, with per-bot folder sharing.
- **Computers, browsers, and applets** your bots can use and build.
- **Tools**: dozens of MCP services, plus on-device OCR.
- **On-device models**: Apple Intelligence, Qwen3, Llama, Gemma 4.
- **Native chat**: voice, screen capture, annotations, Quick Look.
- **Always on**: heartbeats, notifications, Spotlight, Shortcuts.

## Documentation

- [Working with agents](docs/usage.md)
- [Harness setup](docs/harness-setup.md)
- [Noodle in the enterprise](docs/enterprise.md)
- [Noodle Computer](Computer/README.md)
- [Noodle Applet](Applet/README.md)
- [Noodle Browser](Browser/README.md)
- [Architecture](docs/architecture.md)
- [Security and privacy](docs/security.md)
- [Development and testing](docs/development.md)
- [Contributing](CONTRIBUTING.md)
- [Code of Conduct](CODE_OF_CONDUCT.md)
- [Releases](docs/releases.md)
- [All documentation](docs/README.md)
- [Changelog](CHANGELOG.md)
