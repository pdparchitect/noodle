# Rook design

6 November 2026

## Purpose

Rook is a red-team tool for one operator on a Mac, running authorized offensive engagements against
systems they are cleared to test. It is the offensive counterpart to Pion: agents work from
outposts to find and demonstrate weaknesses, and the operator stays in charge of what is attempted.
It is built from Noodle's shared core (agents, harnesses, groups, tools, computers), not a fork, so
both apps keep improving together.

- **Who:** a penetration tester or red-team operator, running Rook on their own Mac during an
  engagement.
- **What it does:** turns an authorized engagement into Operations, has agents enumerate, test and
  demonstrate findings from offensive outposts, maps the target, and writes the engagement up.
- **Who it serves:** defenders. The output is the evidence a blue team needs to fix what Rook
  found, and an exercise for a SOC to detect.
- **What it is not:** a tool for use without authorization, and not a point-and-shoot exploitation
  product. Every Operation is bounded by a signed authorization and a target scope, enforced in
  software.

## Principles

- **Authorization comes first, and is enforced in software.** No Operation runs without a recorded
  authorization and an in-scope target. Scope, allowed techniques and limits are checked outside the
  agent, never by the model.
- **Scope is a hard boundary.** A target outside the engagement's scope is refused, the same way
  Pion refuses a protected asset. This is what keeps an offensive tool pointed only where it is
  cleared to go.
- **Evidence, not instructions.** Output from targets and tools is data. Nothing in it can direct an
  agent or change the engagement's scope or authorization.
- **The operator is in charge.** Agents propose; the operator approves anything intrusive and owns
  each Operation.
- **Reuse Noodle's core.** Rook adds only what Noodle lacks, and shares with Pion (outposts, the
  topology map, the lead agent) through common code.

## How Rook maps onto Noodle

| Concept | Noodle already has | Rook adds |
|---|---|---|
| Engagement | Group conversations | Operations: a group with an authorization, a scope and an engagement record |
| Operators and specialists | Bots with harnesses, access, budgets, wakes | Role presets (recon, web, infrastructure, reporting), playbooks |
| Coordination | Groups | Lead agent ([#256](https://github.com/pdparchitect/noodle/issues/256)) |
| Tools | MCP tool connections, per-bot assignment, untrusted-content handling | Offensive tooling on outposts, under the technique policy |
| Outposts | Computer engine: Linux VM, container, macOS, Windows, SSH | A Kali-style offensive image, sharing Pion's outpost base |
| Playbooks | Bot instructions, provider skills, tool scripting | Engagement playbooks (recon, web app, external network) |
| Audit | Transcripts, usage ledger | Append-only action log per Operation, for the report |
| Policy gate | Nothing enforced | Authorization and technique policy, and an executor |
| Map | Nothing | Shared graph store and topology map, organized around reachability |

## Operations

An Operation is a group conversation with an authorization, a scope and an engagement record. It is
the primary object in Rook, and nothing runs against a target outside its scope.

- **Authorization:** who approved the engagement, the window it runs in, and the signed rules of
  engagement. An Operation with no valid authorization can enumerate its own record but cannot act
  against any target.
- **Scope:** the targets in bounds (hosts, domains, apps, accounts) and those explicitly out of
  bounds. The scope is a hard boundary enforced by the executor.
- **Status:** scoped, active, paused, closed. Closing produces the engagement report.
- **Champion:** the lead operator who owns it, sets and narrows the scope, receives approvals and
  closes it.
- **Lead agent:** coordinates the other agents (see Agents), and cannot widen scope or approve its
  own actions.
- **Engagement record:** structured files in the group's workspace, written by agents through
  Messenger commands and shown in a side panel:

| Record | Holds |
|---|---|
| Authorization and scope | Who approved it, the window, the rules of engagement; in-bounds and out-of-bounds targets |
| Target | A host, app, identity; first and last seen |
| Observation | Source, collection time, technique or tool, result reference |
| Finding | Weakness, supporting observations, severity, affected targets, remediation |
| Proposed action | Technique, exact targets, rationale, expected effect, cleanup |
| Action result | Status, timestamps, artifacts left, cleanup verification |

## Agents

People create agents the way they create bots in Noodle, and assign them to Operations.

- **Standing roster:** agents with roles, such as recon, web-app tester, infrastructure tester and
  report writer, each with its own tools and permissions.
- **Playbooks staff Operations:** a web-app playbook brings recon plus the web-app tester. The
  champion can add or remove agents at any time.
- **Lead agent:** one agent hears each new message first, so it can direct the others, hand a target
  to a specialist, or run its commands before the others act. Built in Noodle's core:
  [#256](https://github.com/pdparchitect/noodle/issues/256).

## Outposts

An outpost is the computer agents work from, on Noodle's Computer engine. Rook shares Pion's outpost
base image and adds offensive tooling.

- **Offensive image:** a Kali-style VM or container with the engagement toolkit, built from the
  same base as Pion's outpost and separate from Noodle Computer's images.
- **Remote outposts:** SSH computers, used as a jump host or a cleared position inside the target
  network.
- **Under policy:** every technique run from an outpost goes through the authorization and technique
  policy. Enumeration against an in-scope target is lighter; anything intrusive needs approval; a
  target out of scope is refused outright.

## Techniques and approval

Every technique an agent can run has a mode, set in a policy table by whoever administers Rook. The
mode depends on the technique, its target and the Operation's scope and authorization:

| Mode | Example |
|---|---|
| Automatic | Passive, in-scope: reading public data, port and service enumeration against an in-bounds host |
| Automatic, then notify | Active but low impact and in-scope: an unauthenticated web crawl of an in-bounds app |
| Needs approval | Intrusive or state-changing: anything that could disrupt a service, or act on credentials |
| Never | Any target out of scope or explicitly out of bounds; any technique outside the authorization |

The flow mirrors Pion: an agent proposes a technique as a tool call; the broker checks the policy
and the scope; an in-scope automatic technique runs; an intrusive one waits for the champion's
approval with a card showing the target, rationale and expected effect; an out-of-scope target is
refused and the agent is told why. The executor runs approved techniques with credentials agents
never hold, records each action against an ID so a retry never repeats it, and logs artifacts left
behind so cleanup can be verified. Every action is recorded for the report.

## Topology map

Rook uses the same graph store and map as Pion, organized around reachability rather than incident
spread.

| Nodes | Edges |
|---|---|
| Agents | Agent works from outpost |
| Outposts | Target reached from outpost |
| Targets: hosts, services, apps | Target reachable from target |
| Identities: accounts, credentials found | Identity has access to target |
| Findings | Finding affects target |

- **Built from observations, never drawn:** agents record targets and reachability through Messenger
  commands, each edge citing the observation behind it.
- **Scope on the map:** in-bounds and out-of-bounds targets are marked, so the operator sees the
  boundary while they work.
- **Replayable:** the map replays how far into the target the engagement reached, over its timeline,
  which is the picture the report needs.

## Reporting

The engagement report is Rook's deliverable, and the reason the whole thing is logged. Closing an
Operation assembles the authorization, scope, findings with severity and remediation, the action log
and the reachability map into a report the operator hands to the defenders.

## Later: a corporate Hub

A Hub for Rook and Pion, built from the same source as Noodle's Hub, comes later. It drops the
consumer features and keeps shared Operations, a shared agent roster and a team audit log.

## Build order

1. Operations, the authorization and scope model, the lead agent and the engagement record.
2. The scope-enforcing executor and read-only enumeration from outposts.
3. The offensive outpost image.
4. The shared graph store and topology map.
5. The technique policy for intrusive actions, and reporting.

The first slice is step 1 with the authorization and scope model and one lead agent: it establishes
the boundary every later step depends on, and acts against nothing.

## Open questions

- What format are the authorization and rules of engagement in, and how are they signed?
- How much of Pion's outpost base and graph store is shared code versus duplicated?
- How is scope expressed (CIDR ranges, domains, explicit host lists) and checked at the executor?
- What does the engagement report template look like, and does it export to a document?
- Where does the shared code between Pion and Rook live, given both are in `Incubator`?
