# Changelog

## [Unreleased]

### Added

- Google Workspace Containment in Settings › Tools, a tool of its own beside Google Workspace Audit with a sign-in of its own: agents see whether a user is suspended, an admin or enrolled in 2-step verification, the apps they granted access and their app passwords. Agents can also sign a user out everywhere, revoke an app's access, delete an app password, and suspend or restore a user, each only once you approve it. Its Setup Steps make an admin role with only Users › Read, Suspend users and User Security Management.
- Approvals, as in Noodle: an agent's call to a tool marked destructive, such as suspending a user, waits for you in a new Approvals section at the top of the sidebar, which stays there while anything waits, and in a notification that comes through even with Pion in front. Each shows exactly what will run and the agent's reason; approve or decline it there. The Dock counts it, the agent is told the outcome, and the Investigation's Audit Log records the request and how it was decided.
- A guide to both Google Workspace tools in `docs/tools`: the access each asks for, the least access to set it up with, and their caveats.
- A tool's activity says how many requests an agent's call or a check for alerts retried because the service rate limited them or was briefly unavailable, on that call's or check's own line, such as "Checked for alerts: nothing new (2 requests retried)".

### Changed

- A tool's description and instructions follow its catalogue entry's current text until you change them, so tools you have not edited pick up improved defaults. A field you changed has a reset button in its corner that puts the default back.
- Google Workspace is called Google Workspace Audit, and its Setup Steps have you sign in as an admin kept for Pion whose role holds only Reports, never a super admin.
- Google Cloud is called Google Cloud Audit, as it only reads.

### Fixed

- Google Workspace Audit no longer fails its alert checks with "Request rate higher than configured": it sends Google at most 8 requests at once, and a request a tool's service rate limits is tried again after a pause, for up to 30 seconds. A quota that still refuses is shown as rate limiting, not as missing permissions.

## [0.8.0] - 2026-11-21

### Added

- An Investigation an agent opens shows a notification as soon as it is opened, even with Pion in front, naming the agent, the Investigation and its objective; clicking it opens the Investigation.
- Pion's banner artwork is kept in the repository, so its README screenshots can be retaken over it with `scripts/readme-shots.sh`.
- Click a tool in the sidebar to open its page where a conversation would be: where it stands and the button it needs, the agents it is assigned to, which you add or remove there, its watch for new alerts (how many checks, what the last one found, when the next is due, and each wake with the agents it woke), the tools it offers, and its activity since Pion started, newest first: which agent called which of its tools, how long each call took and why any failed, its sign-ins and sign-outs, a sign-in, token or credentials it is missing, why it could not be offered to agents at all, and each check for new alerts. A run of the same line, such as checks that found nothing, shows as one, saying how many times and since when.
- cve.now in Settings › Tools, with nothing to set up: agents look up a CVE, GHSA or OSV entry, search for vulnerabilities by product, package or whether they are exploited, read feeds of new and critical ones, and check a project's dependencies, through cve.now's free MCP server. CVEs joining the top 10 of its Index, the worst of the past seven days, wake the agents it is assigned to; Pion reads it every hour.
- Cloudflare Radar in Settings › Tools, signed in with any Cloudflare account: agents read Internet-wide attack and traffic trends, outages, BGP hijacks and route leaks, network, IP address and domain details, and URL scans, through Cloudflare's Radar MCP server.
- Google Workspace wakes the agents it is assigned to for audit events that mean an attack, checked every five minutes with the sign-in it already has: suspicious and blocked sign-ins, leaked passwords, hijacked accounts, government-backed attack warnings, admin privileges granted, primary admin, SSO and 2-step verification changes, compromised devices and rules that fired above low. Agents read them with its new `security-events` tool.

### Changed

- The Grafana you run is called Self-Hosted Grafana in Settings › Tools, as Self-Hosted Sentry is, so it is told apart from Grafana's MCP server.
- Unrestricted access is off until turned on with `defaults write com.pdparchitect.pion AllowUnrestrictedAccess -bool true`; until then Settings › Bots hides it, and agents that had it run restricted, keeping it for when it is turned on.
- Settings › Tools says an account Pion watches is "Watched for new alerts", and the note that wakes its agents is `<tool-alerts>`.

### Fixed

- A link's card under your own message lines up with the right edge of the message, not partway in.
- Tools that watch for new alerts are checked as soon as Pion starts. Before, the first check after launch found none of them ready and skipped them silently, so their activity stayed empty for five minutes. An account's activity also says when it starts being watched, and a watched tool assigned to no agent says it is not checked until it is assigned.
- A tool that works again wakes the agents it is assigned to and tells them, so one waiting on it retries and carries on; nothing told them before. That is when it is signed in again after failing or being signed out, and when a failed tool comes back by itself: a call that works shows it, and every five minutes a failed tool is checked. Its tools are listed in their skills before they are told, even if it never listed them before; its failure mark clears, and its activity says it is working again and who was told.
- Tools that watch for new alerts wake the agents they are assigned to: the watch found none of them, so no new alert, and no CVE joining the cve.now Index, woke anyone.
- An MCP server that needs no sign-in, added by its address, connects and works: Connect finds it answers without one, instead of failing on the sign-in details it does not publish.

## [0.7.0] - 2026-11-19

### Added

- The skill of each tool that wakes its agents for new alerts says what the `<pion-alerts>` note's parts mean and which tool reads the alerts.
- Settings › Tools says which accounts wake their agents for new alerts, and why one could not be checked.
- GitHub lists an organisation's open code scanning and Dependabot alerts beside its leaked secrets, by kind and from a time on, and wakes its agents for every new leaked secret and new high or critical code scanning and Dependabot alerts. A feed the organisation has not turned on leaves the others to be read.
- More tools wake their agents for new alerts: high-severity Microsoft Sentinel incidents, high and critical CrowdStrike Falcon alerts, every SentinelOne threat, users Entra ID newly rates at high risk, Proofpoint threats delivered or clicked through, and open critical and high Wiz issues.
- Wiz issues can be listed from a time on.
- New high alerts wake the agents a tool is assigned to: Pion checks Microsoft Defender XDR's alerts and Google Cloud's Security Command Center findings every five minutes with the account's own sign-in, and tells the agents only where to look and the time window, so they read the alerts themselves and decide how far to go. An account starts from when it is first watched, so its past alerts are not news.
- Google Cloud's Security Command Center findings can be listed from a time on.
- `scripts/scenario.sh --shots` photographs the window over a picture of your choosing with `--background`, its frosted glass showing the picture through as on a desktop, and `--margin` sets how much of the picture shows around it.
- View › Sidebar › Show Tools lists your tool connections at the foot of the sidebar as flat icons in the text colour, light or dark to match the window, with a red dot on any that needs you to sign in or has failed. Click one to see where it stands and to connect, sign in again, edit or sign out; one that needs no sign-in, such as NVD, offers Try Again after a failure.
- Unread conversations carry Noodle's blue dot in the sidebar, beside agents, groups and Investigations alike; a muted group's is dimmed.
- The Usage window shows each agent's mark beside its name when grouped by bot; click it for the agent's profile, to message it, suspend it or anything else the profile offers.

### Changed

- View lists Sidebar before Conversation, as Noodle does.
- The comment popover's icon takes the title's colour instead of the accent.
- GitHub signs in instead of taking a pasted token: register an OAuth app for the organisation with device sign-in turned on and enter its client ID, then approve the code Pion shows on GitHub. Accounts added with a token keep working with it.
- Markdown headings in a message show as bold lines rather than with their # signs, quoted lines are set in with a bar beside them, and a line of dashes draws a rule.
- Lines an agent starts with a dash, a star or a number show as a list, with wrapped lines lined up under the text and a little space between items, and every paragraph, list and code block in a message is spaced the same.
- The conversation's reading column is narrower, about 85 characters to a line instead of 110, so long messages read more easily; the message field narrows with it.
- Sheet buttons such as Cancel and Create, the add buttons in pickers, the unread dot and folder icons take Pion's accent, or the one you chose in System Settings, instead of a fixed blue.
- Link buttons, such as Profiles in Settings › Harness, take Pion's accent too, the same colour as links in messages, instead of the system's fixed link blue.
- Each agent's mark is a chess piece on a flat grey disc, in place of the rings of arcs: a pawn, knight, bishop, rook, queen or king, always the same one for that agent, however it is renamed.
- A group's mark shows its agents' own pieces together, the lead's in front, in place of the people symbol.
- Links in messages take Pion's accent, its deep blue or the accent you chose in System Settings, instead of the system's fixed link blue. In dark mode a deep accent is lightened just enough to read; a bright one is left as it is.
- Pion's buttons, selections and links take its own deep blue, from its artwork, when your accent colour in System Settings is Multicolour, the default; any other accent you pick still applies.
- A new app icon: Pion's pawn on a flat tile of its blue, flat as Noodle's icon is.
- AWS, now AWS Security, signs in through your organisation's IAM Identity Center instead of access keys, and one connection covers every account you are assigned: enter the AWS access portal URL and a permission set's name, and approve the code on your organisation's sign-in page. Agents list the accounts and name one in each lookup, an access key is traced to its own account first, and the connection stays signed in for as long as your organisation lets a session last.
- An agent's skill for each tool says what every option takes, such as a range of 1–50 or a short list of choices, so it picks a value the tool accepts instead of guessing and being refused.

### Fixed

- A tool that needs no key or sign-in no longer offers Reconnect or Sign Out in Settings › Tools; after a failure it offers Try Again.
- View › Enter Full Screen always has its separator above it: Pion now carries its own item, as Noodle does, instead of AppKit's, whose separator a rebuilt menu could lose.
- A message's attachments wrap side by side again: they have the whole column, rather than the share its text leaves, so two annotations fit on a row.
- Google Cloud audit log searches that Google fails every time are read again in small pages, and one that fails partway keeps the entries already found and says where it stopped, instead of ending in an error.
- A name in code that ends like a web address, such as session.id in a code block or report.md in backticks, no longer gets a link preview card.
- Pion opens on the conversation you left it on, or, if that one has gone, on the one with the latest activity, instead of on no conversation at all.
- The button that suggests another agent name sits as close to the field's edge as Noodle's.
- The window resizes much more smoothly, about twice as fast with an Investigation's case record open and faster for every conversation: the case record is Pion's own panel beside the conversation instead of the system's inspector, which made every step of a resize lay the window out twice, even while hidden. Its edge still drags to resize it, and it keeps the width it was left at.
- The background effect shows through the sidebar and inspector as Noodle's wallpaper does, instead of a blurred copy drawn under each that went wild while the window was resized. The Grid's scan and the Glyphs' rain move smoothly as the window changes height, rather than jumping to another place at every step.
- Google Cloud's audit log search names the audit logs, which Logging finds quickly, instead of matching part of every log's name, which made searches across an organisation fail. A failed search is tried once more, and one Logging did not finish says so instead of reporting no entries.
- A service that limits or fails a request says why, such as which quota ran out and for which project, so the person knows what to raise.
- AWS Security's credential report and access-key tracing work: IAM and STS answered in a form Pion did not read. A lookup AWS turns down says what AWS said, such as Security Hub not being enabled or the role lacking a permission, instead of blaming a key.

## [0.6.0] - 2026-11-18

### Added

- Scenarios record as films with `scripts/scenario.sh --video`, as Noodle's do: titles and a backdrop around the recording, closing on Pion's symbol, the camera moving in on the composer or transcript, and sounds for replies. `--no-intro`, `--no-outro` and `--no-titles` leave the title cards out, and `--background` records over a picture or video of your choosing.
- The PHP2Shell scenario plays the investigation as it happens: the team's findings arrive one by one, the case record fills in beside them, and the Investigation moves to Contained.
- A scenario opened to look at, from the picker or `scripts/scenario.sh` without `--shots` or `--video`, stays in its starting state: its timeline plays only when it is photographed or recorded.
- crt.sh in Settings › Tools, with nothing to set up: agents discover the hosts under a domain, including forgotten and staging ones, and the other domains they share certificates with, from every certificate issued for its names in the public Certificate Transparency logs, newest first.

### Fixed

- The case inspector keeps the width you gave it after you visit an agent or group and come back to an Investigation, instead of sometimes narrowing to its smallest and remembering that.
- The Usage window switches back from Disk in less than half the time, with its toolbar in place from the start: on Disk, the period and bot filters stay where they are, dimmed, instead of leaving and coming back late.
- The Usage window no longer holds up while it sums a long history: the last chart stays, dimmed, until the next is ready, and a period, grouping or measure you have already seen shows again at once.

## [0.5.0] - 2026-11-18

### Added

- NVD in Settings › Tools, with nothing to set up: agents find a product as NVD names it, list its new CVEs newest first with their CVSS scores and whether CISA has seen them exploited, read one in full with its affected versions, and see what CISA has lately found exploited.
- Agents open an Investigation themselves for a problem worth its own record, such as one found in a direct conversation, and lead it; you own it as any other, the audit log says which agent opened it, and an agent opens at most three in an hour.
- CrowdSec CTI in Settings › Tools: agents look up what CrowdSec's network has seen an IP address do, one or up to 20 at once, with its reputation, behaviours, the attacks that caught it, MITRE ATT&CK techniques, CVEs, history and scores.
- Sentry and Self-Hosted Sentry, for one you run, even on this Mac or your network, in Settings › Tools: agents list projects, search issues and read an issue's latest event, with its exception, the frames in the service's own code, the request, the user and its tags, only ever reading.
- Clicking a tool's Connected status offers Sign Out, which revokes its sign-in or key at the service where the service allows it, as Google, Okta and GitHub do, and forgets it here; Remove revokes it the same way before deleting the tool.

### Changed

- Saved tool sign-ins, tokens and client secrets are named as tools in Keychain, rather than as MCP connections, which many of them are not.
- Setup Steps have Open in Window, which keeps them in a small window in front of every app while you follow them in the service's console.
- Google Cloud signs in with Google through your organisation's own client, as Google Workspace does, instead of a service account's key file, asking only for Logging's read-only scope and Cloud Asset's and Security Command Center's own; who has access and which resources exist now come from Cloud Asset's read-only analysis and listing by type. Add a Google Cloud account again to use it.
- Editing a catalogue tool lets you change the details you gave when adding it, such as its address or organisation, and no longer shows the header, token address or scope its entry sets; details that move where it points ask for its key again.
- Grafana's and Sentry's MCP servers are offered again in Settings › Tools, marked MCP, beside Pion's own read-only Grafana and Sentry.
- Retire the upgrade step that moved saved tools to their catalogue entries' new IDs. Updates already pass through Pion 0.4.0.
- Grafana's description in Settings › Tools says it is a self-hosted Grafana, without guessing where it runs.
- View › Background lists its animations under Frosted and Solid without an Animation heading or a line under None.
- Pion's own services show their own icons in Settings › Tools, instead of a letter.
- Settings › Tools no longer shows the fixed address of Pion's own tools under their names, and adding a tool no longer notes under its key that it is kept in Keychain.

### Fixed

- Agents no longer post, react or record evidence in a closed Investigation; they can still read it, and ask you in their own conversation to reopen it. Closing it no longer wakes them.
- Agents in the restricted sandbox can run python3, git, make and the other developer tools that come with Xcode or the Command Line Tools, which failed before; they find the tools' own copies first, so each runs at once. The rest of the Mac stays as closed to them as before.
- Google Cloud's access and resource lookups mark what sits in a project pending deletion, which Google keeps listed for 30 days, so it is not taken for live.
- Google Cloud's audit logs for an organisation or folder include what happened inside each of its projects, which keep their own logs, read past Google's first page up to the limit asked for, and look back 30 days unless told otherwise.
- Google Cloud's Security Command Center findings come from Google's current API; the one Pion used no longer answers.
- When a service turns a tool away, Pion's own tools tell a wrong or expired key from one that may not do what was asked, and pass on the service's reason, including Google's and Microsoft's, such as an API not enabled, also when it turns down the request itself.
- Pion's own tools reach a service on this Mac or the local network, such as a Grafana at http://cbk-ops:3000, and say when a service refuses their credentials, finds nothing or limits them, instead of a generic error.
- A tool that cannot reach its service says why, in the system's words, such as a refused connection or an untrusted certificate, instead of only asking to reconnect.
- The Usage window no longer freezes on a long history when you switch between Tokens, Cost and Disk or change the period: it reads usage in the background, and reading a period costs a fraction of what it did.

## [0.4.0] - 2026-11-18

### Changed

- Tools are identified by IDs that never change, whatever a tool comes to be called; tools already added keep working. Pion installs this release before any later update.
- Google Workspace signs in with Google in your browser, as Noodle signs in to Gmail, through an iOS OAuth client your organisation makes for Pion; its service account with domain-wide delegation is gone. Agents see what the admin who signs in may see.
- Grafana in Settings › Tools is now Pion's own, read-only, in place of Grafana's MCP server; an account added before keeps working as a custom MCP connection.

### Added

- Grafana Cloud and Grafana, for one you run, in Settings › Tools: agents find dashboards and the queries behind their panels, run PromQL, LogQL or other queries over a data source, and read firing alerts and annotations, only ever reading. A Grafana on this Mac or the local network can be reached over plain http.
- Each service in Settings › Tools has Setup Steps, a button at the foot of its form: where in the service's console to make the key, token or account it asks for, and the least access to give it, to read or copy and send to whoever sets it up.

### Fixed

- Editing one of Pion's own tools no longer calls it an MCP connection or shows the address it cannot change, drops the notes under its fields, and shows Setup Steps only where a key can be replaced; removing a tool no longer says its sign-in is deleted from Noodle.

## [0.3.0] - 2026-11-17

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
- Scenarios can give agents tasks, pin conversations and show link cards without the network; a new PHP2Shell scenario shows all three.
- Shortcuts actions, as Noodle's: Send to Agent (a message and files to an Investigation, group or agent), Open Conversation and Call Agent, also by voice with Siri.

### Fixed

- The window resizes more smoothly: Solid is now a normal window background and Frosted the system's own frosted glass, which take about a third less work at each step of a resize.
- As in Noodle, Pion opens its main window even when it last quit with it closed, so its other windows come back and a click on a notification has somewhere to open; a sign-in finishing or Send to Pion no longer opens an empty conversation window.
- A reply in the selected conversation while Pion is in the background marks its row and counts on the Dock, as in Noodle. Files dropped on a sidebar row go only where a message could be sent, and a pending file that can't be removed stays and says why.
- An archived agent can be deleted from its editor in Settings › Agents; Delete Agent did nothing for one. A group or Investigation with an archived member can be edited again, and shows that member greyed out until removed, as in Noodle; saving any change failed.
- A picture or file pasted in a conversation while the message field is out of focus waits in the field, as in Noodle.
- A group's lead is marked with a star on its picture in the members grid, as in Noodle, so making an agent the lead no longer shifts the others.
- Closing the welcome asks first, as in Noodle, and leaving counts as Not Now instead of bringing the welcome back.
- Deleting a login in Settings › Harness says so when it can't move its agents back to the default login, and then keeps the login, as in Noodle.
- As in Noodle: long text that can't be attached when pasted stays on the clipboard instead of filling the message field; an agent's voice follows its name until you pick one, and opening Edit Runtime no longer clears the voice; New Agent picks up a harness installed while it is open and needs one to create the agent.
- As in Noodle, a name with several lines or past the length limit, kept from earlier versions, shows its first line, shortened; an agent's first heartbeat counts from what was last said, not from when Pion opened; and a stop that can't be noted in the conversation says so.
- The activity window's scroller hides again when not scrolling, instead of always showing.
- When an agent moves to another harness because its own ran out of usage, or moves back, its conversation says so, as in Noodle.
- As in Noodle, saving an agent with a login profile of another harness uses that harness's default login instead of refusing, and a voice its harness doesn't have leaves the choice to the harness.
- As in Noodle, a pin or notification setting is forgotten once its conversation is deleted, and an archived conversation keeps both until it comes back; pinning something while a group was archived no longer lost the group's pin.
- A voice message shows just its recording, as in Noodle, without a "Voice message" bubble above it; its reactions sit on the recording.
- Archiving an agent takes its conversation out of the sidebar, the Dock count and searches, and out of the window if open, as in Noodle. Archived agents and groups leave nothing unread, and archiving a group takes its shared folders away from its agents, until it is brought back.
- When creating or saving an agent, group or Investigation fails and Pion cannot fully undo it, the error says what failed first, then what could not be undone.
- Group Info's Save stays dimmed until something changes, as in Noodle.
- Each conversation opens where you left it, after Pion quits too, and a message opened from a search or a notification is where its conversation opens, even in a window not open yet, as in Noodle.
- Searching the sidebar no longer slows typing: what was said is searched once typing pauses, in the background, as in Noodle. Messages in a conversation found only by its description no longer fold under Show All.
- A call still ringing when Pion quit rings again when Pion opens, or is left as missed and the agent told, as in Noodle.
- Conversation › Open in New Window stops a floating conversation floating, as the sidebar's does, and both bring forward a window already showing it instead of opening another, as in Noodle. Holding the Call shortcut no longer starts a call and then ends it.
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

- New Group, Group Info and the Investigation sheet are one page, as Noodle's Group Info is: what it is for, the members, then shared folders. They no longer have Team and Tools tabs; an agent's tools are set in its own editor only, and a group never changes them.
- An agent's profile shows the status the agent set for itself, as in Noodle, faded once it may be out of date, and what the agent is doing when it set none. It follows a change made in it for an archived agent too, and its Message button is dimmed when there is no conversation to open.
- Settings › General is Noodle's, so generated agent names are Real or Playful, as there.
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
