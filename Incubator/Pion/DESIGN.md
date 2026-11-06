# Pion design

6 November 2026

## Purpose

Pion is a cyber defence tool for one operator on a Mac: agents investigate incidents through
outposts and connectors, and the operator stays in charge of anything that changes a system. It is
built from Noodle's shared core (agents, harnesses, groups, tools, computers), not a fork of it, so
both apps keep improving together.

- **Who:** a security operator or analyst, running Pion on their own Mac while they work.
- **What it does:** turns signals into Investigations, has agents gather evidence and map what they
  find, and contains threats under a policy the operator controls.
- **What it is not:** a SIEM, log store or endpoint detection product. It works alongside those
  through connectors. It has no applets and, for now, no Hub.

## Principles

- **Policy is enforced in software, never by the model.** Scope, allowed actions, approvals and
  limits are checked outside the agent. Model confidence is never an authorisation rule.
- **Evidence, not instructions.** Logs, tool results and anything collected are data. Nothing in
  them can direct an agent or change policy.
- **The operator is in charge.** Agents propose; the operator approves what needs approval and
  owns each Investigation.
- **Reuse Noodle's core.** Pion adds only what Noodle lacks. Anything useful to both, such as the
  lead agent, is built in the shared core.

## How Pion maps onto Noodle

| Concept | Noodle already has | Pion adds |
|---|---|---|
| Case | Group conversations: shared transcript, attachments, workspace folder | Investigations: a group with scope, status and a case record |
| Investigator and specialists | Bots with harnesses, access, budgets, suspension, wakes | Role presets, playbooks, default teams |
| Coordination | Groups | Lead agent ([#256](https://github.com/pdparchitect/noodle/issues/256)) |
| Connectors | MCP tool connections, the catalogue, per-bot assignment, untrusted-content handling | Security connectors, read-only by default |
| Outposts | Computer engine: Linux VM, container, macOS, Windows, SSH | A Pion image; outpost commands under the action policy |
| Playbooks | Bot instructions, provider skills, tool scripting | Investigation playbooks |
| Triggers | Wakes, heartbeats, inbox turns | Watchers and alert intake |
| Audit | Transcripts, usage ledger | Append-only action log per Investigation |
| Policy gate | Nothing enforced; "confirm before" lives only in prompts | Action policy and executor |
| Map | Nothing | Graph store and topology map |

## Investigations

An Investigation is a group conversation with a scope, a status and a case record. It is the
primary object in Pion.

- **Status:** open, triaging, contained, closed. Closing records an outcome: false positive,
  resolved, or handed off.
- **Champion:** the person who owns it. They set and change the scope, receive approvals, and close
  it.
- **Lead agent:** coordinates the other agents in the conversation (see Agents). It cannot widen
  the scope or approve its own actions.
- **Case record:** structured files in the group's workspace, written by agents through Messenger
  commands and shown in a side panel:

| Record | Holds |
|---|---|
| Objective and scope | What the Investigation is for; the entities and systems it may touch |
| Entity | A host, identity, service, indicator; first and last seen |
| Evidence | Source, collection time, query or method, result reference |
| Finding | Claim, supporting evidence, uncertainty, affected entities |
| Proposed action | Operation, exact targets, rationale, expected effect, how to undo it |
| Action result | Status, timestamps, external action ID, verification result |

## Agents

People create agents the way they create bots in Noodle, and assign them to Investigations.

- **Standing roster:** agents with roles, such as triage, email analyst, endpoint analyst and
  identity analyst, each with its own connectors and permissions.
- **Playbooks staff Investigations:** a phishing playbook brings triage plus the email analyst. An
  Investigation opened by an alert is staffed from its playbook automatically; the champion can add
  or remove agents at any time.
- **Lead agent:** one agent in the group hears each new message first, so it can answer, hand the
  message to another agent with an @mention, or run its commands before the others act. The others
  are released once the lead has acted, or after a short time cap. This is built in Noodle's core:
  [#256](https://github.com/pdparchitect/noodle/issues/256).
- **Unattended alerts:** the lead triages, then closes the Investigation as a false positive or
  assigns it to a champion with a summary. It never widens its own scope.

## Outposts

An outpost is a computer agents investigate from: a pivot for running tools and reaching systems.
It runs on Noodle's Computer engine.

- **Prebuilt outposts:** a VM or container from a Pion image with the investigation toolkit
  installed, built separately from Noodle Computer's images. Used to examine suspicious files and
  run tools away from the operator's Mac.
- **Remote outposts:** SSH computers, used as pivots inside a network segment, a jump host or a
  cloud account.
- **Under policy:** commands on an outpost go through the same action policy as connectors. Reading
  is automatic; changing a remote system, such as killing a process or changing a firewall, needs
  approval. Today a bot with a terminal can run anything, so this is new.

## Actions and approval

Every action an agent can take has a mode, set in a policy table by whoever administers Pion:

| Mode | Example |
|---|---|
| Automatic | Read-only, or reversible and in scope: enrichment, tagging, snapshotting a host, adding an indicator to a watchlist |
| Automatic, then notify | Low impact and reversible, but visible: forcing a password reset on an in-scope test account |
| Needs approval | Containment, destructive or hard to undo: isolating a host, revoking an OAuth app, disabling a user |
| Never | Outside the scope, or protected assets such as domain controllers and executive accounts |

The mode depends on the action, its target and the Investigation's scope. A worked example:

1. The lead agent calls `isolate_host(host: "LT-0423", reason: "beaconing to known C2")`, like any
   other tool.
2. The call passes through the tool broker, which looks up the policy:
    - **Automatic:** it runs, and the result returns to the agent.
    - **Needs approval:** it does not run. The agent gets "pending approval, action A-17", and the
      Investigation shows the champion a card with the target, rationale, evidence and how to undo
      it, with Approve and Deny.
    - **Never:** it is refused, and the agent is told why.
3. When the champion approves, the executor runs the call with credentials agents never hold,
   records the outcome against A-17, verifies the effect, and posts the result. The agent is woken
   with the outcome.
4. A retry finds A-17 already done, so the action is never repeated.

Write-capable connectors live only behind the executor; agents get the read-only side.

## Signals and watchers

Pion runs while the operator's Mac is on, and catches up on signals when it opens.

- **Watchers pull, they don't wait for pushes:** a watcher polls one source (SIEM alerts,
  identity-provider events, a mailbox) from a saved checkpoint, so nothing is lost while Pion is
  closed.
- **Watchers are code, not agents:** they filter and deduplicate, and only a match opens an
  Investigation and wakes its lead. No model runs to look at noise.
- **Local signals:** endpoint events and the unified log from the operator's Mac, while it runs.
- **Always live:** Pion can run from the menu bar as a login item, so live means logged in.

## Topology map

The topology map shows agents, the outposts they work from, and the assets found from each outpost,
with each Investigation laid over it.

| Nodes | Edges |
|---|---|
| Agents | Agent works from outpost |
| Outposts | Asset reached from outpost |
| Assets: hosts, services, cloud resources | Asset talks to, logged into, runs on asset |
| Identities: users, service accounts, OAuth apps | Identity has access to, signed in from asset |
| Indicators: IPs, domains, hashes | Indicator seen on asset |

- **Built from evidence, never drawn:** agents record entities and relationships through Messenger
  commands. Each edge cites the evidence behind it, and is shown as unconfirmed until evidence
  supports it.
- **Freshness:** every entry keeps first and last seen, so stale entries fade.
- **Two layers:** the environment, one map shared across Investigations that grows over time; and
  each Investigation on top, with affected entities, the attack path and actions taken, replayable
  on a timeline.
- **Tied to the rest:** choosing entities on the map sets scope; marking protected assets feeds the
  policy; approval cards show the target's place on the map.
- **Built as:** a small graph store (entities, relationships, evidence, first and last seen) and a
  SwiftUI map grouped around outposts.

## Later: a corporate Hub

A Hub for Pion and Rook, built from the same source as Noodle's Hub, comes later. It drops family
sharing, devices and the other consumer features, and keeps shared Investigations, a shared agent
roster and a team audit log. Investigations and case records are plain app-owned data, so nothing
built first blocks it.

## Build order

1. Investigations, the lead agent and the case record.
2. Read-only connectors and outposts.
3. The graph store and topology map.
4. The action policy and executor.
5. Watchers.

The first slice is step 1 with one lead agent and read-only connectors: useful on its own, and
safe, because it cannot change anything.

## Open questions

- Which security connectors come first?
- What goes in the Pion outpost image?
- Who edits the action policy, and is it per Investigation, per playbook, or global?
- How does an Investigation's scope get set when an alert opens it?
- Where does Rook fit alongside Pion?
