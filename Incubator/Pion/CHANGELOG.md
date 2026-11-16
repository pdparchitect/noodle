# Changelog

## [Unreleased]

### Added

- The agent editor has Noodle's Spending Budget: a token limit over a period, after which the agent finishes its turn and waits until older usage leaves the period or you reset it.
- For a harness with voices, the agent editor offers the voice the agent speaks with on calls, and plays each one, as in Noodle.
- Delete Agent and Delete Group, at the bottom of their editors, ask first and say what goes with them, as in Noodle.
- Reactions, as in Noodle: agents' reactions such as 👀, ⏳ and ✅ show on their messages, and right-clicking a message reacts, with More Emoji…; clicking a reaction shows who reacted and lets you change or remove yours.
- Tasks, as in Noodle: View › Sidebar can list the agents' tasks above the conversations, all open ones or only those waiting on you. Clicking one writes to its agent about it, and that message is labelled with the task.
- As in Noodle, the conversation's toolbar says why an agent doesn't answer and offers Sign In, Unsuspend or Kick, and an agent's menu in the sidebar has Organize, Kick and New Session.
- Pasting a picture or file into the message field attaches it, and so does long text; Edit › Paste as Attachment (⌥⌘V) attaches any text, as in Noodle.
- The Dock shows how many conversations wait for you, as in Noodle: muted groups never count, and a group set to mentions counts once a reply names you.
- Your messages say whether they were Saved, Sent, Delivered or Not delivered, and a message's first web link gets a preview card, as in Noodle.
- The Help menu starts with Pion Help, which opens Pion's page, as Noodle's does.
- Pin and Unpin, in a conversation's menu, keep Investigations, groups and agents in a Pinned section at the top of the sidebar, in the order pinned, as in Noodle.
- View › Sidebar has Noodle's choices of the line under each name (description, which Pion shows unless you pick another, latest message or status) and of the order: Newest First, Unread First or an Unread section.
- Search Conversations also finds messages, as in Noodle: Investigations, groups and agents that match come first, then each message that says the term, with the words around it; picking one opens the conversation at that message.
- A file in a message has Noodle's menu: react, Copy, Quick Look, Save…, Show in Finder and Forward…, which sends it on to another conversation with a comment. Files drag out to Finder and other apps, and a file dropped on a sidebar row is forwarded there, or waits in that conversation if it came from elsewhere.
- As in Noodle, an annotation you haven't sent yet waits in its conversation after Pion quits.
- A patch or diff an agent sends opens in Noodle's review: each file's changes, ticking files off as viewed, and commenting on selected lines or marking a region, which waits in the message field as any annotation does.
- Settings › Conversation has Noodle's Message received sound, played when a reply arrives while Pion is in front and by the notification otherwise, and Noodle's Keep one floating conversation.
- As in Noodle, the harnesses Pion installed update by themselves while it runs (unless turned off in Settings › Harnesses), and agents stopped by sleep start again as soon as the Mac wakes.
- A conversation in a window of its own has Show in Main Window, as in Noodle; its window opens again where it was when Pion opens, and closes when the conversation is deleted.
- As in Noodle, files dropped anywhere on a conversation wait in its message field, the conversation outlined while they are over it.
- Tab in the sidebar goes to the message field and Shift-Tab there goes back, as in Noodle.
- The message field says when nothing can be sent because the agent, or every agent of a group, is archived, as in Noodle.
- In a group, an agent's profile has Reply, which addresses the agent at the start of your message, as in Noodle.
- A group's name at the top of its conversation opens its profile, as in Noodle: what it is for, who is in it, and Edit.
- A voice message's menu has Show Transcript, as in Noodle.
- View › Conversation › Attachments lays out a message's files as Noodle can: side by side, one below another, or stacked; and View › Hide Sidebar (⌃⌘S), as in Noodle.
- Send to Pion, Noodle's Share extension: share text, links, pictures or files from any app's Share menu into an Investigation, group or agent, with an instruction; Pion picks them up as your message, opening if it isn't.
- Services › Send to Pion…, Noodle's Send to Agent…: selected text, a link or files from any app, sent with the same window.
- Shortcuts actions, as Noodle's: Send to Agent (a message and files to an Investigation, group or agent), Open Conversation and Call Agent, also by voice with Siri.

### Fixed

- Sending works as in Noodle: files sent without words say how many there are instead of listing their names, a message sent from Shortcuts marks its conversation read, and Forward… offers only conversations that can take a message, not an archived agent's.
- Files and photos you pick go to the conversation you picked them for, even if you switched to another while choosing, and a photo that can't be read is reported instead of dropped, as in Noodle.
- Changing a group's members or description wakes its agents to read the notice, as in Noodle.
- New messages are found as Noodle finds them: Pion's own notices, such as a new lead, no longer make a conversation unread, reactions (yours included) reach the other agents, an agent that just spoke isn't woken by its heartbeat, and a transcript rewritten within the same second is still read.
- As in Noodle, a reply is read when its conversation is on screen, in the main window, a window of its own or a floating one; before, only the main window's selection counted, even with Pion in the background, and a notification for a conversation open in its own window opened it in the main window too.
- Something going wrong is said over whichever Pion window is in front, a sheet or a floating conversation included, as in Noodle; before, it waited for the main window and went unseen while that was closed.
- Picking a message in search results or in a notification scrolls to it, and a conversation you come back to opens where you left it while Pion runs; before, Pion lost its place in the transcript.
- In a team with a lead, the lead hears your message first, as the team editor says and as in Noodle, also when you send from the message field or with Forward…; before, only an Investigation's opening message did that, and the rest woke everyone at once.
- A call from an agent stops ringing as soon as the agent is archived or deleted, as in Noodle, instead of ringing on until it was missed.
- An agent waiting for sign-in while it runs on a fallback login comes back by itself once that login works again, as in Noodle; Pion checked the agent's own login instead.
- Apple Intelligence is no longer Unavailable in the welcome on a Mac that has it: Pion adds Apple's on-device model once for a new install, where before it waited to be added in Settings › Harness. Removed there, it stays removed.
- In Settings > Agents, an archived agent's picture no longer opens its profile; bring the agent back with its Archived switch first.

### Changed

- Tables in messages sort by a click on a column heading, and the menu in their corner copies a table as CSV or saves it, as in Noodle.
- A long conversation opens quickly, as in Noodle: it shows its newest 100 messages and the 100 before each time you reach the top.
- A file waiting in the message field is Noodle's chip: it copies, drags out to Finder and other apps, and has Noodle's look.
- An agent's and a team's Tools are Noodle's list: each tool has Edit and Remove beside it, and removing one asks first.
- The agent editor's Harness rows are Noodle's: they also say when a harness always has unrestricted access or could not list its models, and choosing another harness starts on its default model.
- An agent's profile is Noodle's card: a close button, Archived for an archived agent, and clicking outside or leaving Pion closes it.
- A conversation's menu in the sidebar is in Noodle's order: where it opens, Pin and Notifications, editing, Show items, the agent's housekeeping, then Stop, Suspend and Archive or Close. Stop shows only while the agent works, and Open in New Window brings a floating conversation back into a window.
- Float on Top is Noodle's: the conversation moves to a small panel that stays above other apps, on every Space and beside full-screen apps, and floats again where it was after Pion reopens. It's also in each conversation's menu in the sidebar. Before, it only raised the window it was chosen in, until Pion quit.
- The agent editor names a harness's default login by its account, as Noodle does, instead of Default.
- Groups and agents in the sidebar come newest message first, as in Noodle, instead of by name; open Investigations still come most severe first.
- Removing an agent from a team or group asks first, as in Noodle, and inline code in messages reads as in Noodle.
- A notice such as an agent moving to another harness, or someone joining a group, shows as Noodle's small centred note instead of a message from Pion.
- The microphone and ⇧⌘D send voice messages, as in Noodle: the recording, with its transcript, goes to the conversation, and agents hear what was said. They used to dictate into the message field. In Settings › Keybindings the shortcut is now Record / Stop Voice Message.
- Pion has no conversation picker: Conversation › Choose Conversation and its ⌃⌥Space shortcut are gone, as is its row in Settings › Keybindings. The sidebar and Search Conversations find conversations; a conversation in a window of its own has no search.
- Settings › Keybindings no longer lists Usage, as in Noodle; ⇧⌘U still opens it.
- In the Usage window's Disk measure, Sign-ins is now Logins: each login's folder holds what its harness keeps there, such as Codex's plugins, not only the sign-in itself.

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
