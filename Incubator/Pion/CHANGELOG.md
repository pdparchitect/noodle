# Changelog

## [Unreleased]

## [0.2.0] - 2026-11-15

### Added

- Usage, as in Noodle: Pion keeps what its agents use, and Pion › Usage (⇧⌘U) shows tokens, cost and storage for every agent. An agent's profile and its menu in the sidebar open it for that agent.
- A welcome on first launch, as in Noodle: choose an account, and Pion installs it and signs in, then makes a starter team (a lead investigator, a triage analyst and a threat intelligence analyst) in a group they share. Help › Welcome and Set Up Your Team in the empty window bring it back.
- The Help menu has Report a Bug and Request a Feature, which open a new GitHub issue with Pion already chosen as the affected area.
- Settings has a Keybindings tab, as in Noodle: change, clear or reset any of Pion's shortcuts, including New Investigation, Show Inspector, Close Investigation, Capture, Dictate, Call and the annotation shortcuts.
- Voice calls, as in Noodle: call an agent whose harness has voices from its conversation's toolbar, its profile or Conversation › Call (⇧⌘C), with the call's card and what was said in the conversation. Agents can call you too; the call rings in a panel until you answer or decline, and a missed call is left in the conversation.
- Settings has a Groups tab, as in Noodle, to archive a group or bring an archived one back.
- Notifications, as in Noodle: agent replies while Pion is in the background, sign-ins and pauses. Settings > General chooses whether groups notify every reply or only mentions of your name, each group's menu in the sidebar can set its own, and Settings > Permissions shows notification access.
- Settings has a Conversation tab, as in Noodle: message delivery, new sessions, the microphone, descriptions in the @ name menu and web link previews.
- An agent's profile has Suspend beside Message and Edit; a click offers how long, and a suspended agent shows Unsuspend.

### Changed

- Codex, Claude and Apple Intelligence are the harnesses on for a new install and offered by the welcome; Grok, Muse and the rest wait to be turned on in Settings > Harness.
- With nothing set up, the sidebar shows no empty Investigations or Agents headings, and the window says No Agents with a short prompt to create one.
- Settings badges the Harness, Tools, Permissions and Update tabs when they need attention, and is as wide as Noodle's.
- The Agents tab in Settings has Noodle's sparkles icon.
- The activity window shows each entry's time in teal, so it stands apart from the title and output.
- In Settings > Agents, an archived agent says Archived instead of when it was last active, and its switches other than Archived are dimmed.

### Fixed

- An agent archived in Settings > Agents stays listed there, so it can be brought back.
- The activity window shows the arrow pointer over its scroller and Follow Latest button, instead of the text cursor.

## [0.1.0] - 2026-11-15

### Fixed

- Smoother conversation scrolling: unchanged messages reuse their formatted text when rows redraw.
- Background effects and working agents' rings no longer slow the app: both are drawn outside the main thread.
- Dictation no longer changes the message field's height, and its waveform fills the field.
- The message field's + button opens Noodle's attachment menu.
- Evidence and team tool rows expand when clicked anywhere, not only on the chevron.
- A conversation's heading no longer sits under the toolbar.

### Changed

- Pion's sheets use Noodle's wording: an agent's private text is its Backstory, every text field has a placeholder, and small text under the description, backstory, objective, note and team says who sees each one.
- Settings › Tools › Add Tools lists Pion's security services and only the general services that help an investigation: Atlassian, Linear and Notion for tickets and notes; Axiom, Datadog, Grafana, Honeycomb and Sentry for observability; Semgrep, Socket and Sourcegraph for code; Cloudflare; and Exa, Perplexity, Tavily and Parallel Search for research.
- Settings › Agents shows each agent's mark in place of a pencil. As in Noodle, clicking it opens the agent's profile, with buttons to message it in a window of its own or edit it.
- Investigations have no scope. Creating and editing one asks for its title, objective, team and tools; agents are told to stay on the objective.
- Investigations start unassessed, and only their lead agent sets the severity, through the case tool, with a note in the audit log. The toolbar shows it.
- Switching conversations works as in Noodle: the transcript dissolves into the next one while the toolbar, message field and inspector stay in place, so nothing flashes. Clicking a conversation puts the keyboard in its message field; moving with the arrow keys keeps it in the sidebar.
- Pion no longer asks for the camera, calendars or reminders, which it does not use.
- Agents have generated marks of their own, kept through renames, in place of symbols.
- The audit log reads as a timeline grouped by day, with each event named and marked.
- Team members are added and removed as in Noodle's groups, in place of checkboxes. Members are changed from the editor, so the Members toolbar button is gone, as are the sidebar's plus buttons.
- Dictation stops with Return or the stop button; the Done button is gone.
- The agent editor's Runtime section is now Harness, with Noodle's harness, model and reasoning choosers.
- The Grid background ripples with pings that lift and push the dots they pass.
- Background effects carry on under the sidebar and inspector, softened by their frosted glass, and are fainter, so text stands out.
- Sheets use Noodle-style top action bars and rounded text fields, with multiline descriptions and Return left to the focused field. Scenarios use generated agent names throughout their conversations and mentions.
- New agents start with generated names, with a Human option and a button to try another name. Agents and groups can be edited from their sidebar context menus or the conversation toolbar.
- The View menu separates the inspector from display options and keeps the window's background together in one submenu: Frosted or Solid, then the effects Grid, Network and Glyphs. Pion starts frosted, with no effect.
- A Conversation menu replaces Investigation, with search, a conversation picker, separate conversation windows, Float on Top, dictation and Stop. Investigation status and closing stay in the investigation's toolbar.

### Added

- An Investigation or group has a lead only when you choose one: in its editor, right-click an agent and choose Make Lead. The lead hears your messages a few seconds before the others, so the team stops answering all at once, and only the lead sets severity and status. Without a lead, severity stays Unassessed.
- View › Background › Solid gives the window a plain background in place of the frosted glass the desktop shows through. Frosted, the default, brings the frost back.
- Proofpoint TAP, Sumo Logic, Tenable and Censys in Settings › Tools › Add Tools. Proofpoint takes a service principal and secret, Sumo Logic its deployment with an access ID and key, Tenable an access key and secret key, and Censys a personal access token. Agents can see the last hour's email threats and clicks, search logs, see an asset's vulnerabilities by IP address, and see what an internet host exposes.
- Google Cloud and Google Workspace in Settings › Tools › Add Tools, each with a service account's JSON key. Google Cloud takes an organization, folder or project, for audit logs, Security Command Center findings, who has access to what, and resource search. Google Workspace takes the admin to act as, for sign-in, admin, OAuth token, Drive and other audit reports. Both only read, and the key never leaves the Mac.
- AWS in Settings › Tools › Add Tools, each account added with a default region and a read-only IAM user's access key. Agents can look up CloudTrail events, list GuardDuty, Security Hub and IAM Access Analyzer findings, trace an access key to its owner and last use, read the credential report, find EC2 instances by ID or IP address and security groups open to the internet, and query CloudWatch Logs Insights. Requests are signed with the key, which never leaves the Mac.
- AbuseIPDB, urlscan.io, GreyNoise, AlienVault OTX and Have I Been Pwned in Settings › Tools › Add Tools, each with its API key. Agents can see an IP address's abuse reports and whether it is internet background noise, search earlier scans of web pages, find community threat reports that mention an indicator, and check the breaches and pastes an email address appears in. Nothing is reported or submitted for scanning.
- Cloudflare Security, Wiz and GitHub in Settings › Tools › Add Tools. Cloudflare Security takes an account ID and an API token, for DNS records, the account audit log and a zone's firewall events. Wiz takes its data center and a service account's client ID and secret, for cloud security issues and read-only queries over its security graph. GitHub takes an organisation and a token, for its audit log, members and outside collaborators, and secret scanning alerts.
- Splunk, Elastic and Microsoft Sentinel in Settings › Tools › Add Tools, so agents can search logs in SPL, ES|QL and KQL. Splunk takes its address and an authentication token, Elastic its address and an API key, and Sentinel its tenant, workspace and an app registration's client ID and secret. Searches only read; Splunk commands that write or send are refused.
- CrowdStrike Falcon and SentinelOne in Settings › Tools › Add Tools. Falcon takes its cloud and an API client's ID and secret, SentinelOne its console address and an API token. Agents can find hosts and agents, with their status, containment and last activity, and list the alerts and threats raised on them.
- Microsoft Entra ID and Microsoft Defender XDR in Settings › Tools › Add Tools, each tenant added with its directory (tenant) ID and an app registration's client ID and secret. Agents can find users and see their groups, roles and sign-in methods, read sign-in logs and risky users, list Defender alerts and incidents, and run read-only KQL hunting queries.
- Shodan in Settings › Tools › Add Tools: agents can see what an IP address exposes, with its open ports, services and known vulnerabilities, and resolve hostnames and addresses both ways.
- Okta in Settings › Tools › Add Tools: add each org with its domain and an API token, and assign it to agents, who can find users, see their groups, apps and sign-in factors, and search the System Log by user, IP address, event type, failures and time. Nothing changes the org.
- VirusTotal in Settings › Tools › Add Tools: add it with your API key and assign it to agents, who can look up the reputation of file hashes, domains, IP addresses and URLs. Lookups never submit anything for scanning.
- Tool connections can use a token instead of signing in through the browser, as in Noodle: in Settings › Tools, Custom MCP's Sign-in choice of Token takes an API key and the header it goes in.
- Tool connections can also use a client ID and secret, as in Noodle: Custom MCP's Client ID & Secret choice takes the service's token URL and both values.
- Attachments work as in Noodle: add a file, a photo or a capture of a window from the + menu; files show as pictures and cards in messages and open in Quick Look; annotate a file, a link, a region or selected text, from the preview or with Conversation › Add Annotation and Annotate Region.
- Clicking an agent's mark opens its profile, with buttons to message or edit it.
- General, Permissions and Update settings. Released builds update themselves from Pion's own channel, and Pion › Check for Updates looks now.
- Keep Mac awake while agents work, in General settings, as in Noodle.
- Suspend an agent for an hour, four hours, until tomorrow, a week or until unsuspended, from its sidebar menu, as in Noodle. A suspended agent finishes its turn, then waits, and says until when.
- Export an Investigation as one zip, from its sidebar menu, the Export menu in its toolbar or Conversation › Export Investigation…: its details, case record, audit log, messages and attachments, to archive or share.
- Sidebar menus laid out as in Noodle, the same for Investigations, groups and agents: open, edit, status, Show in Finder, Show Activity, then stop, close or archive. Closed Investigations have the menu too. Messages, files, findings, evidence, entities and audit entries have their own menus to copy, look at or find what they show.
- Assign shared folders with read-only or read-and-write access to agents, groups and investigations. Agent editors now have General, Runtime and Tools sections, including harness profiles and reasoning effort. Add, configure and assign tool connections to agents, including from team editors; assignments reach the running agents and can be revoked. Investigations can be edited from their toolbar or context menu.
- Pion's first version: Investigations, groups and agents in one sidebar, each Investigation with an objective, a status, a severity set by its lead agent, a lead agent and a case record of entities, evidence and findings beside the conversation.
- Conversations read as documents: agents' messages fill a reading column with their name above, yours sit on the right, and nothing is folded away.
- A message field with @mentions, attachments and dictation that turns speech into text before you send it.
- An append-only audit log for every Investigation.
- Settings for harness sign-in, agents and MCP tools.
- Scenarios, played and photographed with `scripts/scenario.sh`.
