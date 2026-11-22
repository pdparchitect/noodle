<div align="center">

<img src="Support/AppIcon.png" alt="Pion" width="96">

# Pion

**AI-assisted cyber defence.**<br>
A team of AI agents monitors your environment, investigates incidents and recommends responses,<br>
using the security tools you already have. You decide what changes.

<a href="https://github.com/pdparchitect/noodle/releases/download/pion-latest/Pion-arm64.dmg"><img alt="Download Pion for Mac" src="https://img.shields.io/badge/Download%20for%20Mac-1f2328?style=for-the-badge&logo=apple&logoColor=white" height="44"></a>

[Website](https://websecurify.com/pion) · [Get started](#get-started) · [Features](#features) · [Tools](#tools) · [Changelog](CHANGELOG.md) · [License](LICENSE.md)

</div>

<p align="center">
  <img width="100%" alt="Pion on a Mac: the team works an impossible-travel sign-in for the finance director. Five agents report the stolen session, the stealer and the files it read, and the case record beside them lists the findings, evidence and entities." src=".github/readme/hero.png" />
</p>

Open an Investigation and a team of agents works it with you: one leads, the others
trace sign-ins, read endpoint telemetry, check reputation and pull the logs. They record
what they find as they go, with the evidence behind it, and bring you what needs a
decision. **Agents never change a system themselves:** they recommend, and you act.

Each agent runs on the [harness](https://github.com/pdparchitect/noodle/blob/main/docs/harness-setup.md)
you choose, with your own account: **Codex**, **Claude Code**, **Apple Intelligence** on
device, or any other harness Noodle supports.

<table>
  <tr>
    <td width="50%" valign="top">
      <img width="100%" alt="The PHP2Shell Investigation, contained: tasks waiting on you sit at the top of the sidebar, beside the case record." src=".github/readme/tasks.png"><br>
      <b>Waiting on you.</b> What needs your decision sits at the top of the sidebar.
    </td>
    <td width="50%" valign="top">
      <img width="100%" alt="The Detection group: the triage agent sums up the night's alerts and another offers a tuned detection rule." src=".github/readme/groups.png"><br>
      <b>Groups.</b> Standing teams for the work between incidents.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img width="100%" alt="A credential phishing Investigation with its Audit Log: every finding, piece of evidence and status change, and who made it." src=".github/readme/audit.png"><br>
      <b>Audit Log.</b> Every change to the case and who made it, only ever added to.
    </td>
    <td width="50%" valign="top">
      <img width="100%" alt="Welcome to Pion: sign in to Codex, Claude or Apple Intelligence to set up your team." src=".github/readme/welcome.png"><br>
      <b>Ready in minutes.</b> Sign in once and Pion sets up a starter team.
    </td>
  </tr>
</table>

## Get Pion

| App | What it does | Download |
| --- | --- | --- |
| **Pion** | AI-assisted cyber defence. | [![macOS 26 DMG](https://img.shields.io/badge/macOS_26-DMG-0A84FF?logo=apple&logoColor=white)](https://github.com/pdparchitect/noodle/releases/download/pion-latest/Pion-arm64.dmg) [![macOS 26 ZIP](https://img.shields.io/badge/macOS_26-ZIP-0A84FF?logo=apple&logoColor=white)](https://github.com/pdparchitect/noodle/releases/download/pion-latest/Pion-arm64.zip) |

Pion needs a Mac with Apple silicon and macOS 26 or later. Open the DMG and drag Pion to
**Applications**. Pion keeps itself up to date. To remove it, drag it from Applications to the Bin.

Pion is incubating: it works, and it changes quickly. Expect new features in most
releases, and the odd rough edge.

## Get started

1. Open Pion and sign in to a harness on the welcome screen. Pion sets up a starter team
   of agents and the group they share.
2. Connect the services your team should use in **Settings → Tools**, and assign each to the
   agents that need it.
3. Choose **File → New Investigation** (⌘N), say what happened, and pick the team. Or just tell
   an agent what you have seen: when it finds something worth a record, it opens the
   Investigation itself and leads it.

<details>
<summary><b>Investigations, groups and agents</b></summary>

The sidebar lists your Investigations, most severe first, then your groups and your agents.
**View → Sidebar** can also list the tasks waiting on you, closed Investigations and your
tools, with a red dot on any that needs you to sign in.

An Investigation is a conversation with its team, with an objective, a status, a severity
and a case record. One agent leads it; you own it. It starts unassessed until the lead sets
its severity from the evidence. The lead can bring in agents it already works with in
another group or Investigation, and take out those whose part is done; the Audit Log says
who it added or removed. The toolbar sets its status and edits its title, objective
and team. **Investigation → Close Investigation…** closes it as a false positive, resolved
or handed off, with a note; its agents can still read it, but no longer post or record in it.

A group is a standing team you talk to outside any Investigation, such as detection
engineering or threat research. Each agent also has a conversation of its own with you.

Write in the field at the bottom; Return sends. Mention an agent with @. The plus attaches
files, and the microphone (⌘⇧D) turns what you say into text to read over before sending.

</details>

## Features

- **Investigations** with a lead agent, a team, a severity and a status you control.
- **A case record** beside each one: findings with the evidence they cite, evidence with the
  query that produced it, and the entities involved.
- **An Audit Log** of every change to the case, only ever added to.
- **Groups** of agents for the work between incidents.
- **Tasks** waiting on you, at the top of the sidebar.
- **Woken by alerts**: new high alerts in Microsoft Defender XDR, Microsoft Sentinel, CrowdStrike,
  SentinelOne, Entra ID, Proofpoint, Wiz, Google Cloud Audit, Google Workspace Audit and GitHub, and CVEs joining the top of the
  cve.now Index, wake the agents those tools are assigned to, who read them and decide how far to look.
- **Approvals**: agents investigate freely; a change that cuts off access or deletes something
  waits for you, at the top of the sidebar and in a notification, and runs only once you approve it.
- **Your own AI**: Codex, Claude Code, Apple Intelligence and more, on your accounts.
- **Restricted by default**: each agent works in a sandbox of its own on your Mac.
- **Native and fast**: voice input, attachments, annotations, Quick Look, notifications.

## Tools

Connect your stack in **Settings → Tools**. Each service's form has **Setup Steps**: where in
the service's console to make its key or account, and the least access to give it. Pion's
own lookups only read, and their actions wait for your approval. Add two accounts of the same service side by side, and assign each
to the agents that should use it.

| | |
| --- | --- |
| **Reputation and intel** | VirusTotal, Shodan, Censys, GreyNoise, CrowdSec CTI, AbuseIPDB, AlienVault OTX, urlscan.io, Have I Been Pwned, Cloudflare Radar |
| **Attack surface** | crt.sh, DNS, NVD, cve.now, Tenable |
| **Identity** | Okta, Microsoft Entra ID, Google Workspace Audit, Google Workspace Containment |
| **Endpoint and email** | CrowdStrike Falcon, Microsoft Defender XDR, SentinelOne, Proofpoint TAP |
| **Logs and monitoring** | Splunk, Elastic, Microsoft Sentinel, Sumo Logic, Grafana, Sentry |
| **Cloud and code** | AWS Security, Google Cloud Audit, Cloudflare Security, Wiz, GitHub |

Any MCP server works too. AWS Security signs in through your organisation's IAM Identity
Center and covers every account you are assigned; Google Cloud Audit and both Google Workspace
tools sign in with your Google account; GitHub signs in with a code, through an OAuth app your
organisation registers.

Some services have a guide in [docs/tools](docs/tools) explaining the access each tool asks for,
the least access to set it up with, and its caveats.

## License

Source available under the [PolyForm Noncommercial License 1.0.0](LICENSE.md): free to
read, use and change for noncommercial purposes. This is not an open-source license.
Pion is built on [Noodle](https://github.com/pdparchitect/noodle), which is open source
under Apache 2.0.

## Project

[Website](https://websecurify.com/pion) · [Changelog](CHANGELOG.md) · [Contributing](CONTRIBUTING.md) · [Noodle](https://github.com/pdparchitect/noodle) · [Rook](https://github.com/pdparchitect/rook) · [@pdp on X](https://x.com/pdp)
