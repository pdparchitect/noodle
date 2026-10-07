# Changelog

## [Unreleased]

## [0.22.0] - 2026-10-07

### Added

- People can talk to bots that run on their owner's Mac, shared from Noodle. The Hub keeps their conversations and shows the bot online while that Mac is connected; it runs nothing of the bot. Settings → Bots shows which Mac such a bot runs on.

### Fixed

- Restricted bots can no longer connect to other programs on the Mac through local sockets, such as ssh-agent, Docker or other apps' helpers. Internet access and the bot's own workspace are unchanged.

## [0.21.0] - 2026-10-07

### Added

- Coinbase can be added as a tool.
- The Hub keeps each user's pins for its bots and groups, so a pin made in the Hub's space on one device shows on all of them.

## [0.20.0] - 2026-10-06

### Added

- AgentMail, Airtable, Amplitude, Apify, Asana, Atlassian, Axiom, Cal.com, Calendly, Circleback, ClickHouse, Close, Cloudinary, Contentful, Convex, Coupler.io, Datadog, Dropbox, ElevenLabs, fal, Fathom, Gamma, Grafana, Guru, Harmonic, Hex, Honeycomb, Intercom, Lucid, Mem, Mercury, Mermaid Chart, Mixpanel, MotherDuck, Otter, PostHog, Postman, Railway, Read AI, Readwise, Semgrep, Socket, Sourcegraph, Square, Tavily, tl;dv, Upstash, Whimsical and WordPress.com can be added as tools.

### Fixed

- Settings > Network > Name shows the current name, ready to edit, and says to press Return while a change is unsaved.
- Claude Code bots that hand work to background agents now show as working until that work finishes, and the follow-up they post afterwards appears in the activity log, instead of showing "Claude Code ready" while they are still busy.

## [0.19.0] - 2026-10-05

### Added

- People can call their Codex bots, and Codex bots shared with them, from Noodle and Noodle for iPhone. The Hub starts the bot if needed, uses the voice chosen in its editor on the Mac or iPhone, or one that suits its name, and keeps the call and what was said in the conversation. The audio goes between the person's device and OpenAI, not through the Hub. Someone a bot is shared with calls it on its owner's plan, as they talk with it, and the call stays in their own conversation.

## [0.18.0] - 2026-10-05

### Added

- The Hub can be given a name of its own in Settings > Network > Name, so it is not known by the Mac's name. Paired devices pick up the new name the next time they check in, within a minute. Clearing the name goes back to the Mac's.
- People can choose a picture for themselves from their phones and Macs: a photo, or a symbol or their initials on a colour. Everyone on the Hub sees it when sharing a bot, and the Hub shows it in Settings > Users and when pairing a device. Removing someone removes their picture too.

### Changed

- Activity in the menu bar menu is now called Logs, so it is not mistaken for a bot's activity, and its person menu has more room.
- Bots know who owns them from the start, not only once their owner writes to them, and follow a new name.

### Fixed

- Noodlets a bot shares show their names on paired phones again, instead of all being called Noodlet.

## [0.17.0] - 2026-10-04

### Added

- Users can be made admins in Settings > Users. The Hub lets an admin's devices add, rename and remove the users who are not admins, move them to another plan, and invite or unpair their devices, ready for Noodle and Noodle Mobile to offer it. Only the Hub's own Settings makes or changes admins.
- A bot's owner can share it with other people on the Hub from Noodle or Noodle Mobile. Each person talks with the same bot in a conversation of their own, on the owner's plan, and the bot knows them by name. They only talk with it: they see whether it is working but never its backstory, harness or the status it sets, never open its computers or browsers (noodlets it shares open as usual), and cannot edit, kick, archive, delete or share it. Only the owner shares it or stops sharing it, which removes that person's conversation with it. While the owner has it archived, it is gone from the others' devices, and it comes back with their conversations when brought back. Stopping sharing or archiving cuts them off at once: noodlets of it they opened stop working, live views close and notifications of its replies go. Activity records who shared which bot with whom, who stopped, and refused attempts.
- Activity in the menu bar menu lists who added, changed or removed users, made invitations and paired or removed devices, on the Hub or from a device, and every attempt the Hub refused, with its reason. Entries are kept for 90 days, and a person can be chosen to see only what concerns them. However many refused requests a device sends, they never push out the record of a change.

### Changed

- A device that leaves the Hub in Noodle or Noodle Mobile is removed from Users, and Activity records it.

## [0.16.0] - 2026-10-03

### Added

- Apple Intelligence bots can use Ollama on the Hub's Mac, added in Settings > Harness > Apple Intelligence > Remote Models without an API key.

## [0.15.0] - 2026-10-03

### Added

- Keeps each conversation's background for all its user's devices, and makes a small copy of a background video for phones.

### Fixed

- Settings > Groups scrolls a long list of groups, as Settings > Bots does, instead of growing past the screen.

## [0.14.0] - 2026-10-03

### Added

- Devices can archive their bots and groups, and bring them back. An archived bot keeps everything but stops running and takes no messages; an archived group keeps its messages, takes no new ones, and its bots keep running.
- Settings > Bots has an Archived switch for each bot, and the new Settings > Groups tab lists every group with its owner and bots, each with an Archived switch. Click a group's picture for its profile and folder; a bot's or group's profile says when it is archived.
- Apple Intelligence bots can use remote models with the Hub's own API keys, added in Settings > Harness > Apple Intelligence > Remote Models.

### Changed

- Settings > Bots now holds the Heartbeat and Sandbox settings: each bot's row has its Heartbeat, Unrestricted and Apps switches. Click a bot's picture for its owner, harness and status, Show Folder, Activity and New Session.
- Bots use Noodle Applet through an applet tool, like computers and browsers, instead of their own `noodlet` command. The Hub no longer ships the command, and updating removes it, its skill and its mailbox from every bot's workspace. Update to Noodle Hub 0.14.0 before any later version, so the old command is cleaned up.

### Fixed

- Muse Code bots in the macOS sandbox start conversations again. Muse Code 1.4.2-R4684.1 stopped with "deletion registry authority is unavailable".

## [0.13.1] - 2026-10-02

### Fixed

- Mobile can show the titles and previews of shared noodlets without opening them. Update Mobile too.

## [0.13.0] - 2026-10-01

### Added

- Network shows whether devices away from home can reach the Hub, through Tailscale, the internet or your own address, and turns orange when the router could not open the port and nothing else reaches it.
- Open Port on Router says where the router opened the port or why it did not, and each address is tagged home, Tailscale or internet.

### Changed

- Network is laid out like This Mac in Noodle's Hub settings, with Add Remote Address in the list instead of at the bottom of the window.
- Retire naming each bot's owner in its files when the Hub opens, which bots from before 0.6.0 needed. Updates already pass through 0.6.0.
- A noodlet that asks for the local network runs on the device that opens it, which asks the person first; the Hub never streams it.

### Fixed

- A paired device can no longer fill the Hub's memory by sending on a live view or update stream: the Hub closes a stream that sends more than it reads.
- A noodlet a device opens or watches live is checked by Noodle Applet too as the sharing bot's own, as it reads its files, data and secrets, so a bot cannot swap in another bot's noodlet after the Hub's check. Update Noodle Applet as well.

## [0.12.0] - 2026-10-01

### Added

- Paired phones and Macs can run a bot's noodlets themselves instead of watching them live. Only the person who has the bot can open them, and their data and secrets are kept on the Hub, which the device reads while it runs them. A noodlet that uses the camera, microphone or screen is never streamed, since it would get the Hub's; the device runs it. Needs the latest Noodle Applet.

## [0.11.0] - 2026-09-30

### Changed

- A device that falls behind in a live view picks up again from a small picture built on what it already shows, instead of a full new picture about 40 times larger. The Browser, Computer or Applet and the device need their latest versions.
- Live views start live on a slow connection: the first picture comes at a moderate rate and more follows as soon as the device confirms it can take it, instead of the first seconds arriving late.
- Brief wobbles on Wi-Fi no longer make live video lighter than the connection allows.
- A live view on a congested connection asks for one fresh picture and waits for room, instead of asking again after every picture it could not use.

## [0.10.0] - 2026-09-29

### Changed

- Live views stay live on a slow connection: the Hub sends less as soon as a device says pictures are arriving late, instead of letting them pile up in the network and show a second or more behind. Devices need the latest Noodle or Noodle for iPhone for this.

## [0.9.0] - 2026-09-29

### Added

- Settings > Companion Apps lists Noodle Mobile, with a link to join its TestFlight beta.
- Klaviyo and Evernote can be added as tools.
- Games your bots make can show a controller on iPhone and iPad instead of the keyboard, when the game says which keys it uses.

## [0.8.0] - 2026-09-29

### Added

- A status a bot sets through Messenger reaches Noodle on the Mac and on iPhone and iPad.

### Fixed

- In Settings > Bots, a bot's status lines up with Show Folder, Activity and New Session.

## [0.7.0] - 2026-09-29

### Added

- Noodle Hub opens at login, so devices can reach it after the Mac restarts. Turn it off with Open at Login in Settings > Network.
- Kick and New Session work from Noodle on iPhone and iPad for bots on the Hub, with the same questions as in Noodle.
- Noodle for iPhone lists the tool services the Hub offers when adding a tool, as Noodle's New Tool does.
- Noodle for iPhone can set the reasoning effort of a bot on the Hub, from the efforts its model offers.
- The Hub keeps groups of a user's own bots, made and edited from Noodle on the Mac. A group whose last bot is deleted goes with it.

## [0.6.0] - 2026-09-28

### Added

- Settings has Heartbeat and Sandbox tabs, as in Noodle: choose how often idle bots on the Hub wake to check for work, and give each bot unrestricted access or account apps.
- Settings has a Conversation tab, as in Noodle, for message delivery and when idle bots start a new session. Settings > Bots has New Session for each bot, and a bot stopped by the model's safeguards waits for Kick.
- Local Models, in Settings > Harness, offers Qwen3.5 9B, gpt-oss 20B, Qwen3.8 27B, Qwen3.6 35B-A3B and Qwen3 Coder Next for Macs with 16 GB to 64 GB of memory, and Import Model accepts Qwen3.5, Qwen3-Next and gpt-oss models.

### Changed

- Settings opens on Network, now its first tab. Bots comes after Plans, next to the Heartbeat and Sandbox tabs.
- Each bot on the Hub records who it belongs to, so Noodle Applet on the Hub's Mac can list their noodlets under that person. Existing bots are updated when the Hub opens.
- Noodle Computer and Noodle Browser on the Hub's Mac are told whom each computer and browser is for, and group them under those people. Existing ones are updated the next time a device lists them.
- The app icon uses Apple's system blue, the same flat blue as the other Noodle apps.

### Fixed

- Pair… starts from the first step again after the window was closed, instead of reopening on the last one.
- In Settings > Bots, a bot's status now lines up with Show Folder and Activity.

## [0.5.0] - 2026-09-28

### Added

- Settings has a Companions tab to open and update Noodle Computer, Browser and Applet on the Hub's Mac, or download their latest installers. Its badge shows how many have an update.
- A plan can limit which models each harness it lends may use: the link under the harness opens a list to choose them, or All models. Bots on a harness with limited models must use one of them.
- The first launch opens on a welcome, as Noodle's does, that ends in pairing your first device.
- Pair… in the menu bar menu opens a window to pair a new device, under the Noodle wordmark as on the welcome: choose one of the Hub's users or name a new one, then scan its QR code or share its link.
- When the Hub's Mac is on Tailscale, the Hub lists its Tailscale name among its addresses, so devices can reach it wherever they are on your tailnet.
- People can pair more of their own devices from Noodle on their phone. Can Pair Devices, in the actions menu beside each user in Settings > Users, is on unless you turn it off.
- Largest File, in Settings > Network, sets the biggest file people can send to their bots on the Hub, 100 MB unless you change it. A larger file is refused before any of it is kept.

### Changed

- Add User and Add Plan in Settings end in an ellipsis, since they ask for a name.
- Check for Updates in Settings > Update no longer ends in an ellipsis.
- Bots can no longer pop a noodlet window up on the Hub's screen. Their noodlets run out of sight.
- Noodlets the Hub's bots make stay in their own folders, and Noodle Applet runs them there instead of keeping a copy. Update Noodle Applet along with the Hub.
- The Usage window keeps its bot, group, measure and period choices in the toolbar, with the period's dates under the title, totals in one strip above the chart and the breakdown in a table below it.
- Buttons in the rows of the Users, Plans and Bots settings look like links, as in System Settings.
- Invite and Remove in Settings > Users, and Delete Plan, no longer end in an ellipsis, since they ask for nothing more.
- A user's plan is chosen from the Plan submenu of their actions menu in Settings > Users, and shows under their name.
- Quitting the Hub, from its menu or with Command-Q, asks first and says how many people and devices are connected and how many bots are working. Logging out and shutting down are not held up.
- Restarting to install an update asks first in the same way.
- The menu bar menu groups Pair… and Usage apart from Settings…, and Usage no longer ends in “…”.
- The Hub follows the system's light or dark appearance instead of always being dark.

### Fixed

- A file that stops arriving partway, as when a device loses its connection, no longer leaves its pieces taking space on the Hub's Mac. They are deleted after an hour.
- Settings > Network updates the Hub's addresses when its Mac's network changes, such as when Tailscale connects, instead of showing the ones it found when the window opened.

### Security

- A bot on the Hub reaches only its own noodlets and those shared with its conversations, once Noodle Applet on the Hub's Mac is updated. Before, it could list and use every noodlet on the Mac, other people's included.
- Invitations show the Hub's key. Devices show the same key before they join, so the person joining can check it is this Hub.

## [0.4.1] - 2026-09-27

### Changed

- What happens to phones' notifications goes to the system log, under the category Notifications, with any error from iCloud.

## [0.4.0] - 2026-09-27

### Added

- The Hub remembers how far each person has read their conversations, so reading on one device clears the unread dot on their others.
- Phones away from the Hub are notified of new replies.

## [0.3.2] - 2026-09-27

### Changed

- Opening the Hub yourself shows its Settings, so it no longer seems to do nothing. At login it still starts quietly in the menu bar.

### Added

- The menu bar icon shows a green dot while someone is connected to the Hub.

### Fixed

- Each picture's size is sent with it, so Noodle for iPhone keeps its place in a conversation while pictures load.
- Live views keep up on a slow or busy connection: video gets lighter to fit the link instead of arriving seconds late and stuttering.
- Settings, Usage and bot Activity windows open in front of other apps instead of behind them.
- Usage no longer counts a Claude bot’s earlier tokens and cost again each time the bot restarts. Usage recorded before this fix still includes the repeats.

## [0.3.1] - 2026-09-26

### Changed

- Send bot pictures and tool icons apart from their lists to the latest Noodle and Noodle for iPhone, which fetch each once, so lists stay small however many pictures they show. Editing a bot from a device keeps its picture without sending it back.

### Fixed

- Fix a crash when a tool connection fails while the Hub is listing or updating people's tools.

## [0.3.0] - 2026-09-26

### Added

- Reach the Hub away from home. Open Port on Router in Settings > Network asks the router, through UPnP or NAT-PMP, to forward the Hub's port and keeps it open; the router's public address joins the addresses invitations carry, and paired devices pick it up when they next connect. Network says when the router cannot, for example when it sits behind another router or your provider shares its address.
- React to your bots' messages from Noodle for iPhone, and see their reactions there as they happen. Paired devices also see what each bot is doing: working, ready, failed or offline.
- Keep the transcript of voice messages sent to the Hub's bots, so bots read what was said.
- Let the Hub's bots build and share noodlets with Noodle Applet on the Hub's Mac, as they do in Noodle. A noodlet opens live only for the owner of the bot whose folder it came from, however the bot links to it. Install Noodle Applet on the Hub's Mac to use them.
- Show what a bot's browser or computer card points at live to its owner in Noodle, and pass on their clicks, typing and scrolling.
- Run browsers for the Hub's bots in Noodle Browser on the Hub's Mac. People make and delete them from Noodle; each belongs to the person who made it and reaches only the bots they choose. Install Noodle Browser on the Hub's Mac to use them.
- Run computers for the Hub's bots in Noodle Computer on the Hub's Mac. People make and delete them from Noodle; each belongs to the person who made it and reaches only the bots they choose. Install Noodle Computer on the Hub's Mac to use them.
- Keep people's tool connections on the Hub. Each connection belongs to the person who added it from Noodle, reaches only the bots they choose, and keeps its sign-in in the Hub's Keychain, where bots never see it.

### Changed

- Refuse devices that are not paired before reading anything they send. An invitation's code carries a key made for it alone, and only a device holding that code can reach the Hub to join, once; the joining device also proves it holds the key it pairs. A removed device is disconnected at once. Devices join with the latest Noodle or Noodle for iPhone.
- Send conversations to devices a page at a time, newest first, with card pictures fetched separately, so a long conversation loads quickly and never fails for its size.
- A live view of a browser, computer or noodlet in a Noodle Browser, Computer or Applet too old to show it says which app to update.
- Stream live views as video, each picture as soon as it is ready and no larger than the viewer's window, skipping old pictures for a device that falls behind, and take the person's input on the same connection, in order. While someone watches a browser, computer or noodlet, its bot waits until they close the view. A view the Hub cannot open tells the device why.
- Send links to the browsers, computers and noodlets the Hub's bots share as links with their pictures, so devices open them live. Cards the Hub saved earlier become links when it starts.

### Removed

- The Hub's bots no longer call tools on their owner's Mac. Update Noodle on paired Macs along with the Hub.

### Fixed

- Opening the app again brings the copy already running to the front instead of starting a second one on the same data, however it is started.
- Delete a removed tool connection's sign-in from Keychain even when the first try fails. The Hub tries again until it is gone.

## [0.2.0] - 2026-09-25

### Added

- See token use and cost for the Hub's bots by bot, harness or model from Usage… in the menu bar, with the same view as Noodle.
- Add users in Settings > Users and choose which harnesses and profiles they can use with plans in Settings > Plans, where each plan lists what it lends and Edit… switches its harnesses on or off. New users start on the Default plan, which lends nothing until you add to it.
- Pair a Mac running Noodle with the Hub. Invite… next to a user in Settings > Users shows a QR code and a link to copy or share by AirDrop; opening it in Noodle joins the Hub as that user. The device then appears under the user, who can remove it. Each device proves itself with its own key over an encrypted QUIC connection, and invitations work once and expire after 15 minutes.
- See whether the Hub is reachable in Settings > Network: its port and the addresses invitations carry. Add Address records a domain, public address or forwarded port that reaches the Hub from outside your network.
- See who is connected: Settings > Users marks each device that checked in during the last 90 seconds, and Settings > Network counts the people and devices connected now.
- Run the bots people keep on the Hub from Noodle. Each belongs to the user who made it, runs on a harness their plan lends, and talks only with that user; the plan is checked when the bot is made and before every message. Replies reach the user's devices as they are written. Removing a user removes their bots.
- Let the Hub's bots use the tools their owner's Mac lends them. Each call is passed to that Mac, which runs it within what it assigned to the bot; while the Mac is away the bot is told its tools are unavailable.
- See every bot on the Hub in Settings > Bots, with its owner, harness and status, and open its folder or its activity.
- Get Noodle Hub from the Noodle Suite installer, the download table and the website, alongside Noodle's other companions.

### Changed

- Show only Harness, Users, Plans, Bots, Network and Update in Settings for now. Heartbeat, Sandbox, Tools and Companions return when the Hub runs shared agents.

## [0.1.0] - 2026-09-24

### Added

- Try an early development build of Noodle Hub. It does not run bots yet.
- Run Noodle Hub from the menu bar, keeping its bots and data apart from Noodle's. Its Settings cover harnesses, heartbeats, the sandbox, tools, companions and updates, with the same controls as Noodle.
- Check for updates in Settings > Update. Released builds also check once a day.
