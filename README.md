<div align="center">

<img src="Support/AppIcon.png" alt="Noodle" width="96">

# Noodle

**Personal AI agents for your Mac, iPhone and iPad.**<br>
Free and open source. Runs on the AI inference/subscriptions you already have.

<a href="https://github.com/pdparchitect/noodle/releases/latest/download/Noodle-arm64.dmg"><img alt="Download Noodle for Mac" src="https://img.shields.io/badge/Download%20for%20Mac-1f2328?style=for-the-badge&logo=apple&logoColor=white" height="44"></a>

[Website](https://usenoodle.app) · [Apps](#apps) · [Documentation](docs/README.md) · [Security](docs/security.md) · [Privacy](docs/privacy.md) · [Changelog](CHANGELOG.md)

</div>

<p align="center">
  <img width="100%" alt="Noodle on a Mac: Chloe, a personal assistant agent, sends the morning brief and waits for a yes before switching the car insurance." src=".github/readme/hero.png" />
</p>

Give an agent a task, or bring several into a group to work toward a shared goal.
Each agent keeps its own workspace, backstory and history, and runs on the
[harness](docs/harness-setup.md) you choose, using your own account:
**Codex, Claude Code, FX, Grok Build, Muse Code, OpenCode v2, Antigravity** and
**Apple Intelligence** on device.

<table>
  <tr>
    <td width="50%" valign="top">
      <img width="100%" alt="The Morning crew group: three agents research, write and draw a newsletter cover before breakfast." src=".github/readme/groups.png"><br>
      <b>Groups.</b> Several agents in one conversation, working toward a shared goal.
    </td>
    <td width="50%" valign="top">
      <img width="100%" alt="Noodle Mobile on iPhone: the agent list and a group sharing a game an agent built." src=".github/readme/mobile.png"><br>
      <b>Noodle Mobile.</b> Chat with your agents from iPhone and iPad.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img width="100%" alt="Noodle Computer showing an agent's own desktop with a terminal open on /workspace." src=".github/readme/computer.png"><br>
      <b>Noodle Computer.</b> Linux, macOS and Windows computers for you and your agents.
    </td>
    <td width="50%" valign="top">
      <img width="100%" alt="Tabletop Turbo, a racing game an agent built, open in Noodle Applet." src=".github/readme/applet.png"><br>
      <b>Noodle Applet.</b> Tools, websites, experiments and games your agents build.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img width="100%" alt="Noodle Browser with chatbotkit.com open in a browser you sign in to and hand to an agent." src=".github/readme/browser.png"><br>
      <b>Noodle Browser.</b> Signed-in browsers you assign to agents.
    </td>
    <td width="50%" valign="top">
      <img width="100%" alt="Noodle Hub: the people invited to the Hub and the devices they use." src=".github/readme/hub.png"><br>
      <b>Noodle Hub.</b> Share your harnesses with family and friends from an always-on Mac.
    </td>
  </tr>
</table>

## Apps

| App | What it does | Minimum OS |
| --- | --- | --- |
| **[Noodle](https://github.com/pdparchitect/noodle/releases/latest/download/Noodle-arm64.dmg)** | Personal AI agents that get things done. | macOS 26 |
| **[Noodle Suite](https://github.com/pdparchitect/noodle/releases/download/suite-latest/Noodle-Suite-arm64.dmg)** | Noodle and its released companion apps in one installer. Each app updates independently. | macOS 26 |
| **[Noodle Computer](https://github.com/pdparchitect/noodle/releases/download/computer-latest/Noodle-Computer-arm64.dmg)** | Linux, macOS and Windows computers for you and your agents. | macOS 26 |
| **[Noodle Applet](https://github.com/pdparchitect/noodle/releases/download/applet-latest/Noodle-Applet-arm64.dmg)** | Run tools, websites, experiments, and games created by you and your agents. | macOS 15 |
| **[Noodle Browser](https://github.com/pdparchitect/noodle/releases/download/browser-latest/Noodle-Browser-arm64.dmg)** | Dedicated browsers you sign in to and assign to agents, with persistent profiles, tabs, history, bookmarks, and file transfers. | macOS 26 |
| **[Noodle Hub](https://github.com/pdparchitect/noodle/releases/download/hub-latest/Noodle-Hub-arm64.dmg)** | Share your harnesses with family and friends from an always-on Mac. Their bots run there, with your sign-ins kept on the Hub. | macOS 26 |
| **[Noodle Terminal](https://github.com/pdparchitect/noodle/releases/download/terminal-latest/Noodle-Terminal-arm64.zip)** | Chat with the bots and groups on your Noodle Hub from a terminal, on your Mac or on Linux. | macOS 26, Linux |
| **[Noodle Server](Server/README.md)** | A Noodle Hub for Linux: run bots for the people you list on the Claude Code and Codex you install, each in a sandbox of its own. | Linux |
| **[Noodle Mobile](https://testflight.apple.com/join/wYKkNSP9)** | Chat with the agents on your Noodle Hub from iPhone and iPad. Beta on TestFlight: open the link on your phone. | iOS 26 |

Each Mac app link downloads the DMG. Open it and drag the app to **Applications**. ZIP downloads are on the [releases page](https://github.com/pdparchitect/noodle/releases).
Noodle Terminal downloads as a ZIP holding the `noodle` command, or for Linux on
[arm64](https://github.com/pdparchitect/noodle/releases/download/terminal-latest/Noodle-Terminal-linux-arm64.tar.gz)
or [x86_64](https://github.com/pdparchitect/noodle/releases/download/terminal-latest/Noodle-Terminal-linux-x86_64.tar.gz);
[its README](Terminal/README.md) shows where to put it. Noodle Server downloads for Linux on
[arm64](https://github.com/pdparchitect/noodle/releases/download/server-latest/Noodle-Server-linux-arm64.tar.gz)
or [x86_64](https://github.com/pdparchitect/noodle/releases/download/server-latest/Noodle-Server-linux-x86_64.tar.gz);
[its README](Server/README.md) walks through setting it up.
Noodle Computer, Noodle Applet, Noodle Browser, Noodle Hub, Noodle Terminal, Noodle Server, and Noodle Mobile are optional companions and also work on their own.

## Get started

1. Open Noodle and follow **Settings → Harness** to install and sign in.
2. Create a bot, choose its harness, and describe its role in the backstory.
3. Give it a task and the files or context it needs. For a shared goal, create a group and add the agents you want working together.

All harnesses start with restricted access. Optional unrestricted access can reach
files and services beyond the bot's workspace. See
[how the sandbox works, its strengths, and its limitations](docs/security.md).

<details>
<summary><b>Computers, browsers, Hubs and your phone</b></summary>

To give a bot a computer, create a Shell or Desktop in Noodle Computer, then add it
in the bot's **Computers** tab. Several bots can share the same computer.

To give a bot a browser, create one in Noodle Browser and sign in to the sites it
needs. Add it in the bot's **Browsers** tab. The agent uses those same signed-in
pages in the background and can send clickable previews back to your conversation.
Each browser keeps its own sign-ins and browsing data.

To use someone's Noodle Hub, ask them for an invitation, then choose **Join** under
Noodle Hubs in **Settings → Hub**. New bots can then run on the harnesses the
Hub lends you. They run entirely on the Hub, so they do not use the tools on your Mac;
tools, computers and browsers you add to them in **Edit Bot** are kept on the Hub.

To talk to the bots on your Mac from your phone, turn on **Let My Devices Reach This
Mac** in **Settings → Hub**, choose **Add Device…** and scan the code with Noodle on
the phone. Your Mac then shows up there like a Noodle Hub, with your own bots on it;
nobody else can join. The Mac stays awake while this is on. Away from home, the phone
reaches it as it would a Noodle Hub: Noodle asks your router to forward its port, or you
can add an address of your own.

</details>

## Features

- **Persistent agents** with their own workspace, backstory, and history.
- **Groups** of bots working toward a shared goal.
- **Restricted by default**, with per-bot folder sharing.
- **Computers, browsers, and applets** your bots can use and build.
- **Shared harnesses**: run bots on a Noodle Hub that lends you its sign-ins.
- **Tools**: dozens of MCP services, on-device OCR, background removal, etc.
- **On-device models**: Apple Intelligence, Qwen3, Llama, Gemma 4.
- **Native chat**: voice, screen capture, annotations, Quick Look.
- **Always on**: heartbeats, notifications, Spotlight, Shortcuts.

## Documentation

[Working with agents](docs/usage.md) · [Harness setup](docs/harness-setup.md) · [Games](docs/gaming.md) ·
[Noodle Computer](Computer/README.md) · [Noodle Applet](Applet/README.md) · [Noodle Browser](Browser/README.md) ·
[Noodle Hub](Hub/README.md) · [Security](docs/security.md) · [Privacy](docs/privacy.md) ·
[Releases](docs/releases.md) · [All documentation](docs/README.md)

<details>
<summary><b>How Noodle compares</b></summary>

| | Grok Bot | Muse | Noodle |
| --- | --- | --- | --- |
| Models | Grok models only | Muse models only | Bring your own harness (OpenAI, Anthropic, Muse, Fx, Grok, OpenCode) plus local AI models for free |
| Licence | Closed source | Closed source | Open source, Apache 2.0 |
| App | HTML-based, not native | HTML-based, not native | Native and fast, taking advantage of all OS features |
| Computers | Remote VM run by xAI | Remote VM run by Meta | Local desktop-grade secure computers, including first-class support for macOS local accounts |
| Look and feel | Light or dark | Stock | Customise the look and feel to match your preferences: backgrounds, custom icons and more |
| Voice | Sent to xAI's servers | Sent to Meta's servers | On-device dictation and transcription that value your privacy |
| OS integration | Cloud connectors only | Cloud connectors only | First-class OS integration: calendars, shortcuts, reminders, accessibility and much more |
| Tools | Cloud connectors, no local MCP | Cloud connectors, no local MCP | Extensible tool support: any MCP you can think of, plus tool apps installed on your Mac |
| On-device tools | Shell commands only | None | Built-in OS capabilities such as OCR, image generation, background removal and much more |
| Data | Cloud only, no privacy mode | Trains on your chats | Your data stays local |

</details>

## Organisations

Deploying Noodle to your organisation's Macs? Manage it with a configuration profile from Jamf Pro,
Kandji, Intune or another MDM: choose the harnesses, tools, browsers, computers, Hubs and updates
your people can use. This is Noodle Enterprise, in the `Enterprise/` folder under the PolyForm
Small Business License 1.0.0: free for personal use and small businesses, while larger organisations
need a commercial licence to manage Noodle with profiles, which for now we grant free or on
favourable terms. The rest of Noodle
stays Apache 2.0. See [ENTERPRISE.md](ENTERPRISE.md) and the [deployment guide](Enterprise/Deployment.md).

## Project

[Changelog](CHANGELOG.md) · [Contributing](CONTRIBUTING.md) · [Code of Conduct](CODE_OF_CONDUCT.md) · [@pdp on X](https://x.com/pdp) · [All posts about Noodle (devlog)](https://x.com/search?q=from%3Apdp%20noodle&f=live)
