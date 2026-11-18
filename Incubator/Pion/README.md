# Pion

Pion is a cyber defence tool for one operator on a Mac: a team of agents investigates incidents with
you, and you stay in charge of anything that changes a system. It runs agents the way Noodle does,
on the same harnesses, and keeps its own agents, conversations and sign-ins apart from Noodle's.

Pion is incubating: it has no release yet. Build it with `scripts/build.sh` in this folder, which
puts Pion Dev in the repository's `.build` folder.

## Investigations, groups and agents

The sidebar lists your Investigations, most severe first, with closed ones folded under Closed; then
your groups; then your agents. Choose File > New Investigation (⌘N), New Group (⌥⌘N) or New Agent
(⇧⌘N), or the plus beside a section's title.

An Investigation is a conversation with its team, with an objective, a status, a severity and a
case record. One agent leads it; you own it. An agent that finds a problem worth its own record, in
a direct conversation or another Investigation, opens one itself and leads it; it posts there what
started it. It starts unassessed until the lead agent sets its
severity from the evidence; only the lead changes it. The toolbar sets its status, edits its title,
objective and team, and shows the case record. Investigation > Close Investigation… closes it as a false
positive, resolved or handed off, with a note. Its agents can still read a closed Investigation, but
no longer post or record in it; they ask you in their own conversation if it needs reopening.

A group is a standing team you talk to outside any Investigation. Each agent also has a conversation
of its own with you.

## Writing

Write in the field at the bottom; Return sends. Mention an agent with @. The plus attaches files,
and the microphone (⌘⇧D) turns what you say into text in the field, to read over before sending.

## The case record

The inspector beside an Investigation (⌥⌘I) shows what its agents record as they work:
findings with the evidence they cite, evidence with the query that produced it, and the entities
involved. Audit Log lists every change to the case and who made it, and is only ever added to.

Agents never change a system themselves: they recommend changes to you in the conversation.

## Settings

Harness signs in to the harnesses agents run on, Agents changes their models and archives them, and
Tools connects them to services, over MCP or through Pion's own lookups: reputation services such as
VirusTotal, Shodan, GreyNoise and CrowdSec CTI; new vulnerabilities in the products you use, from NVD; the hosts a domain has, from its certificates on crt.sh; identity providers such as Okta, Microsoft Entra ID and Google
Workspace; endpoint and XDR consoles such as CrowdStrike Falcon and Microsoft Defender XDR; log
searches in Splunk, Elastic, Microsoft Sentinel and Sumo Logic; metrics, logs and alerts in Grafana
Cloud or a Grafana you run, and errors in Sentry or a Sentry you run, even on this Mac or your network; and cloud accounts in AWS, Google
Cloud, Cloudflare and Wiz. Add a service, then assign it to the agents that should use it. Each service's
form has Setup Steps, saying where in the service's console to make its key or account and the least
access to give it: Pion's lookups only read. Each service you add is a separate account, so two
accounts of the same service can sit side by side.

## Scenarios

`scripts/scenario.sh` opens Pion in a scenario from `Scenarios/`: a scripted team and
Investigations in a separate copy of Pion Dev with no network and no access to your data. Without a
name it opens the picker. With a name the scenario plays; Return in the terminal, or Scenarios > Next
Step, goes on when it waits. `--shots` saves each captured step to the scenario's `shots` folder, and
`--video` records the scenario to its `recordings` folder, with `--ratio 16:9` and other shapes as MP4s and
the film's titles, camera moves and sounds, as Noodle's scenarios have.

## License

Source available under the PolyForm Noncommercial License 1.0.0: free to read, use and
change for noncommercial purposes. See LICENSE.md. This is not an open-source license.
