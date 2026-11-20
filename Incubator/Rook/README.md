<div align="center">

<img src="Support/AppIcon.png" alt="Rook" width="96">

# Rook

**Autonomous red team.**<br>
A team of AI agents runs an authorized offensive engagement with you: they map the target,<br>
find and demonstrate weaknesses, and write up what they found. You decide what is attempted.

<a href="https://github.com/pdparchitect/noodle/releases/download/rook-latest/Rook-arm64.dmg"><img alt="Download Rook for Mac" src="https://img.shields.io/badge/Download%20for%20Mac-1f2328?style=for-the-badge&logo=apple&logoColor=white" height="44"></a>

[Website](https://websecurify.com/rook) · [Get started](#get-started) · [Features](#features) · [Changelog](CHANGELOG.md) · [License](LICENSE.md)

</div>

<p align="center">
  <img width="100%" alt="Rook on a Mac: a proven Mission against an exposed .git. The agents report a live AWS key in the history and two read-only paths to the production database, and hold for the champion's go-ahead, while the case record beside them lists the findings, evidence and entities." src=".github/readme/hero.png" />
</p>

Open a Mission and a team of agents works it with you: one leads, the others map the
target, probe the web app and follow where a finding leads. They record what they find as
they go, with the evidence behind it, and join the hosts, accounts, credentials and
artifacts into an attack graph. **Nothing intrusive happens without your go-ahead:** agents
stay inside the Mission's scope and ask before they go further.

Each agent runs on the [harness](https://github.com/pdparchitect/noodle/blob/main/docs/harness-setup.md)
you choose, with your own account: **Codex**, **Claude Code**, **Apple Intelligence** on
device, or any other harness Noodle supports.

<table>
  <tr>
    <td width="50%" valign="top">
      <img width="100%" alt="The Mission's attack graph: the leaked key, the accounts and credentials it unlocks, and the hosts, bucket and backup they reach, joined by how one led to the next." src=".github/readme/graph.png"><br>
      <b>Attack graph.</b> Every host, account, credential and artifact, and how one leads to the next.
    </td>
    <td width="50%" valign="top">
      <img width="100%" alt="The Mission with its Audit Log: every entity, link, finding and status change, and which agent made it." src=".github/readme/audit.png"><br>
      <b>Audit Log.</b> Every change to the case and who made it, only ever added to.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img width="100%" alt="The Mission's conversation: the lead operator holds at the door of the production database and asks the champion before pulling proof." src=".github/readme/mission.png"><br>
      <b>Your go-ahead.</b> Agents hold at the door and ask before pulling proof.
    </td>
    <td width="50%" valign="top">
      <img width="100%" alt="Welcome to Rook: sign in to Codex, Claude or Apple Intelligence to set up your team." src=".github/readme/welcome.png"><br>
      <b>Ready in minutes.</b> Sign in once and Rook sets up a starter team.
    </td>
  </tr>
</table>

## Get Rook

| App | What it does | Download |
| --- | --- | --- |
| **Rook** | Autonomous AI red teaming. | [![macOS 26 DMG](https://img.shields.io/badge/macOS_26-DMG-B84756?logo=apple&logoColor=white)](https://github.com/pdparchitect/noodle/releases/download/rook-latest/Rook-arm64.dmg) [![macOS 26 ZIP](https://img.shields.io/badge/macOS_26-ZIP-B84756?logo=apple&logoColor=white)](https://github.com/pdparchitect/noodle/releases/download/rook-latest/Rook-arm64.zip) |

Rook needs a Mac with Apple silicon and macOS 26 or later. Open the DMG and drag Rook to
**Applications**. Rook keeps itself up to date. To remove it, drag it from Applications to the Bin.

Rook is incubating: it works, and it changes quickly. Expect new features in most
releases, and the odd rough edge. Use it only against systems you are authorized to test.

## Get started

1. Open Rook and sign in to a harness on the welcome screen. Rook sets up a starter team
   of agents (a lead operator, recon, and web and app) and the group they share.
2. Choose **File → New Mission**, give it a target and a scope, and pick the team. Or just
   tell an agent what to look at: when it finds something worth a record, it opens the
   Mission itself and leads it.
3. Open the **Graph** in the toolbar to see how far a finding reaches.

<details>
<summary><b>Missions, groups and agents</b></summary>

The sidebar lists your Missions, most severe first, then your groups and your agents.
**View → Sidebar** can also list closed Missions and the tasks waiting on you.

A Mission is a conversation with its team, with an objective, a status, a severity and a
case record. One agent leads it; you own it. It starts unassessed until the lead sets its
severity from the evidence. The status menu in the toolbar moves it between open, active
and proven, and **Close Mission…** closes it as demonstrated, not exploitable or reported,
with a note; its agents can still read it, but no longer post or record in it.

A group is a standing team you talk to outside any Mission. Each agent also has a
conversation of its own with you.

Write in the field at the bottom; Return sends. Mention an agent with @. The plus attaches
files, and the microphone (⌘⇧D) turns what you say into text to read over before sending.

</details>

## Features

- **Missions** with a lead agent, a team, a severity and a status you control.
- **A case record** beside each one: findings with the evidence they cite, evidence with the
  command that produced it, and the hosts, services, accounts, credentials and artifacts involved.
- **An attack graph** of how those connect, which agents read and build on as they work.
- **An Audit Log** of every change to the case, only ever added to.
- **Groups** of agents for standing work between Missions.
- **Your go-ahead first**: agents stay in scope and ask before anything intrusive.
- **Your own AI**: Codex, Claude Code, Apple Intelligence and more, on your accounts.
- **Restricted by default**: each agent works in a sandbox of its own on your Mac.
- **Native and fast**: voice input, attachments, annotations, Quick Look, notifications.

## License

Source available under the [PolyForm Noncommercial License 1.0.0](LICENSE.md): free to
read, use and change for noncommercial purposes. This is not an open-source license.
Rook is built on [Noodle](https://github.com/pdparchitect/noodle), which is open source
under Apache 2.0.

## Project

[Website](https://websecurify.com/rook) · [Changelog](CHANGELOG.md) · [Contributing](CONTRIBUTING.md) · [Noodle](https://github.com/pdparchitect/noodle) · [Pion](https://github.com/pdparchitect/pion) · [@pdp on X](https://x.com/pdp)
