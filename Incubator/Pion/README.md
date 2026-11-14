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
case record. One agent leads it; you own it. It starts unassessed until the lead agent sets its
severity from the evidence; only the lead changes it. The toolbar sets its status, edits its title,
objective and team, and shows the case record. Investigation > Close Investigation… closes it as a false
positive, resolved or handed off, with a note.

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
Tools connects them to services, over MCP or through Pion's own lookups. Add VirusTotal there with
your API key, then assign it to the agents that should check file hashes, domains, IP addresses and
URLs. Add Okta with an org's domain and an API token for agents to look up users, their groups, apps
and sign-in factors, and the org's System Log. Shodan shows what an address exposes. Microsoft Entra ID
and Microsoft Defender XDR take a tenant ID and an app registration's client ID and secret; give the
app read permissions such as User.Read.All, AuditLog.Read.All, SecurityAlert.Read.All and
ThreatHunting.Read.All. CrowdStrike Falcon takes its cloud and an API client's ID and secret with read
scopes for hosts and alerts; SentinelOne takes its console address and an API token. Splunk, Elastic and Microsoft Sentinel let
agents search logs in SPL, ES|QL and KQL: Splunk takes its address and an authentication token, Elastic
its address and an API key, and Sentinel its tenant and workspace IDs with an app registration given the
Log Analytics Reader role. Cloudflare Security takes an account ID and an API token, Wiz its data
center and a service account's client ID and secret, and GitHub an organisation and a token with
read:org and read:audit_log. AbuseIPDB, urlscan.io, GreyNoise, AlienVault OTX and Have I Been Pwned
each take an API key. AWS takes a default region and the access key of an IAM user given the SecurityAudit
policy, plus logs:StartQuery and logs:GetQueryResults for Logs Insights. Each service you add is a separate account, so two accounts of the same service can sit side by
side.

## Scenarios

`scripts/scenario.sh` opens Pion in a scenario from `Scenarios/`: a scripted team and
Investigations in a separate copy of Pion Dev with no network and no access to your data. Without a
name it opens the picker. With a name the scenario plays; Return in the terminal, or Scenarios > Next
Step, goes on when it waits. `--shots` saves each captured step to the scenario's `shots` folder.

## License

Source available under the PolyForm Noncommercial License 1.0.0: free to read, use and
change for noncommercial purposes. See LICENSE.md. This is not an open-source license.
