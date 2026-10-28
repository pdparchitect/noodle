# Changelog

## [Unreleased]

## [0.45.3] - 2026-10-28

### Added

- Harness fallback choices can include specific profiles, including several profiles of the same harness. Bots continue on the next available login when usage runs out, keep their model when switching profiles, and return to their saved login once usage resets.
- Profiles can be opted in to usage retries on their own harness. These are tried before the ordered fallback list and work even when that list is off.

## [0.45.2] - 2026-10-28

### Changed

- Bots read a conversation's history the newest 100 messages at a time, and ask for earlier ones when they need them.

### Fixed

- A bot reading a conversation's history no longer has every attachment in it copied into its workspace again each time. In groups with many files this rewrote gigabytes and took a gigabyte of memory every few minutes, slowing the Mac.

## [0.45.1] - 2026-10-27

### Changed

- Bots are told that a Noodle Browser tab can lose unsent work, for example when only a few pages stay loaded at once, so they keep drafts such as post text and files to attach in their workspace and finish a post before opening other tabs.
- In Settings › Bots, an archived bot's picture is shown in grayscale.

## [0.45.0] - 2026-10-27

### Added

- Plans can be duplicated in Settings › Plans: choose Duplicate in a plan's … menu to get "<plan> Copy" with the same harnesses, models and limits, opened so you can rename or change it. Nobody moves to the copy until you move them.

### Fixed

- A bot paused on a usage limit now resumes by itself once usage is back, when the limit resets or the harness reports usage left again, instead of waiting for Kick. This applies to every harness.

## [0.44.2] - 2026-10-26

### Fixed

- Signing in to Grok Build or Muse Code really no longer opens your browser by itself. Grok Build still found a way around the earlier fix. The sign-in code and Open Sign-In Page show as before.
- The checks the Hub runs on a harness by itself, such as sign-in status, model lists and login renewals, can no longer open your browser.

## [0.44.1] - 2026-10-26

### Fixed

- Renewing a Claude Code sign-in no longer shows "A keychain cannot be found to store …" over and over in the half hour before it expires. Choosing Reset To Defaults there could reset your login keychain.

## [0.44.0] - 2026-10-26

### Added

- You can sign out of a harness in Settings › Harness: click its sign-in status for Sign In Again and Sign Out, and, for Codex and Claude Code, the account it is signed in to. Signing out removes only the Hub's own sign-in for that harness; Noodle's and the one you use in Terminal are kept. Bots that use it pause until you sign in again. A profile's sign-in status in Profiles works the same way.

### Changed

- In a plan, the Default sign-in of Codex and Claude Code shows the account it is signed in to, such as "you@example.com · Default", or "Default · not signed in".

### Fixed

- Claude Code bots no longer all lose their sign-in when one bot's Claude Code gives up on a login a renewal had just replaced.
- Bots waiting for sign-in come back once you sign in again: straight away when you sign in in Settings, and otherwise within a few minutes once their sign-in works. Before, they stayed paused, and the profile kept saying "Sign-in required".
- Starting a harness sign-in, install or update in Settings › Harness shows its progress beside the harness's links instead of on a line of its own, so the rows below no longer jump.

## [0.43.1] - 2026-10-26

### Fixed

- Signing in to Grok Build or Muse Code no longer opens the browser by itself. The Hub shows the sign-in code with Open Sign-In Page, so you open the page when you're ready.

## [0.43.0] - 2026-10-25

### Changed

- The Hub keeps its own sign-in for every harness, separate from Noodle and from the harness in Terminal on the same Mac, so they no longer use up each other's sign-ins. After updating, sign in once in Settings › Harness. Plans without a profile lend this Default sign-in. The copies of the Terminal sign-ins the Hub kept for its bots are deleted, and deleting a profile now also deletes the copy of it its bots shared.
- The Hub renews a Claude Code sign-in itself half an hour before it expires and hands the renewal to its bots, so they no longer all renew at the same moment.

### Fixed

- A Claude Code bot whose sign-in has stopped working now stays paused as "sign-in needed", instead of showing as ready again after each automatic retry. It comes back by itself once the login works again, and tries the same login again after 5 minutes, then twice as long after each refusal, up to every 4 hours, so a login the service turned away only for a moment doesn't leave it waiting.

## [0.42.0] - 2026-10-24

### Added

- Bots are told about Noodle Browser tabs they opened and then left unused for six hours, so they can close the ones they no longer need, as they are about computers they left running. Needs the latest Noodle Browser.

### Changed

- Admins stand out in Settings › Users: an Admin tag in the accent colour beside their name, and Suspended in orange for people who are suspended, instead of grey text after their plan.

## [0.41.1] - 2026-10-23

### Fixed

- The Hub uses less memory: the pictures on shared browser tab, computer and noodlet cards are read when a device asks for them instead of being kept for every conversation.

## [0.41.0] - 2026-10-23

### Added

- Groups can be muted from any device. A muted group sends no notification to devices that are away, and what it already showed is taken back. Unmuting it notifies again from the next reply. Bots' own conversations always notify.
- Groups can be set to Mentions only, one at a time or all at once, from any device. Devices that are away are then notified only of replies that name the user as the Hub lists them, by full name or first name alone, not inside code. A muted group stays silent even for a mention.

## [0.40.0] - 2026-10-22

### Added

- Bots on the Hub can send the new pasta effect, `messenger --effect pasta`, for a moment nobody is quite sure about.
- Devices are told why a bot does not answer for now when it waits for Kick, so Noodle on the iPhone can show it with a Kick button.
- Devices are also told when its owner's plan token limit holds a bot, with when it continues, or when the plan no longer lends it, so Noodle on the Mac and iPhone show it in the bot's status rather than only a grey dot.
- Basecamp can be added as a tool.
- The Usage window can group by user and show one user's usage, with tokens, cost and share per person. Usage from before the Hub kept whose bot it was counts for the bot's owner; usage of someone removed from the Hub, or of a bot deleted before then, shows as Unknown.
- When a plan stops lending a model, its editor in Settings › Plans lists the bots that use it, which can't answer until they move, with Change Model… for each and Move All to… for every one on that harness. Settings › Bots marks them "model not lent", with Change Model… too.

### Changed

- The Hub logs how many devices each call rings through Noodle Push, or that none gave it a grant, and when a device gives or takes back its grant, under Calls in Console.
- A bot can call its owner right away when they wrote to it in the last 5 minutes, such as to ask for a call, even if it called less than 30 minutes ago or already three times today. Calls it places on its own keep those limits.

### Fixed

- A bot's call rings its owner's iPhone through Noodle Push even right after the phone locks or Noodle goes to the background on it. Until then the Hub rang only in-app on a phone that still looked connected, which a suspended app cannot show, so the call never reached the phone.
- Noodle Hub no longer grows in memory after Settings was opened once: the closed Settings window kept updating out of sight for as long as the app ran.

## [0.39.1] - 2026-10-22

### Added

- The Hub records in the Mac's system log every command a bot runs: which bot ran it, the program, when it started and ended, and its peak memory. Command lines and output are not logged; they stay in the bot's conversation. To see the last day's entries, run `log show --predicate 'category == "audit"' --last 1d` in Terminal.

## [0.39.0] - 2026-10-21

### Added

- A bot's call rings its owner's iPhone even while Noodle is closed on it or it is away from home, on the phone's call screen with the bot's name, once Noodle on the iPhone is updated. Answering it from there still needs the phone to reach the Hub.

### Fixed

- The Hub no longer grows in memory as devices use it: each request kept a little memory for good, which added up over days.

## [0.38.0] - 2026-10-20

### Added

- A plan can limit how many tokens each of its users' bots use over a number of hours, days, weeks or months, counted over a rolling period. Once a user reaches it, a turn under way finishes and then their bots stop until the period allows more; messages to them still go through and are answered then. Settings → Users shows how much each user used.
- Admins can also suspend and restore regular users from Noodle Mobile.
- Suspend a user from Settings → Users to stop their bots and block their devices until you restore access, keeping their plan and data.
- Bots whose harness takes voice calls (Codex) can call their owner with messenger --call when something needs them now. The call rings on the owner's devices that run a Noodle with calls, until one answers or declines it or 45 seconds pass; the Hub connects the bot's voice only once it is answered. A declined or missed call leaves a card in the bot's conversation and tells the bot. A bot can call at most once every 30 minutes and three times a day.
- Someone watching one of their browsers live from a device can sign in to the page they see with the device's own fields and saved passwords, once Noodle on the device offers it. Noodle Browser on the Hub's Mac needs updating too.
- Bots on the Hub with a computer have a `terminals` tool that lists their own open terminals there, so they can find and close ones they lost track of.

### Fixed

- A bot without a model runs on its harness's default model, even when the plan lists the models it lends, instead of turning messages away.
- A message to a bot the plan no longer lends is kept instead of showing as not delivered, and the bot reads it once it runs again. In a group, the other bots get it at once.
- A bot the plan no longer lends shows as failed instead of ready.

## [0.37.0] - 2026-10-20

### Added

- Settings → Harness shows how much of the plan limits of each signed-in Codex and Claude Code account is used, and when each resets.

## [0.36.1] - 2026-10-19

### Fixed

- Bots on remote Apple models whose saved catalog default is missing or no longer offered send no reasoning_effort instead of an empty one the provider rejects.

## [0.36.0] - 2026-10-18

### Added

- Krea can be added as a tool.
- A plan can limit how many computers and browsers each of its users keeps on the Hub.

### Changed

- Logs are shown in a monospaced font so their columns line up.
- The Hub's bots can no longer bring up a browser's window on the Hub's Mac; they send a card for the tab instead.

### Fixed

- Comments on attachments reach the Hub's bots with what they refer to, including the comment on a marked-up picture, instead of arriving as plain files.
- A message a bot has taken shows as Delivered on your devices straight away, even when the bot does not reply.
- When the model service is too busy to answer a Codex bot, the bot tries again by itself up to three times over the next few minutes instead of leaving your message unanswered.

## [0.35.3] - 2026-10-17

### Fixed

- A Hub reached through your router comes back within minutes, not half an hour, when the router forgets the port it opened, restarts or gets a new internet address, and right away when this Mac joins another network.
- Closed sheets and Settings windows are freed, so the app no longer slows down the longer it runs.
- A closed Usage window no longer keeps reading usage history, which slowed scrolling and typing.

## [0.35.2] - 2026-10-17

### Changed

- A bot that opens a noodlet and then leaves it unused for 15 minutes is asked to close it, as it already is for a computer it leaves running.

## [0.35.1] - 2026-10-16

### Fixed

- The Usage window's bot menu shows the chosen bot's name next to its picture.
- A bot waiting for sign-in comes back by itself again after the bot changed its own status.
- Bots on a Claude Code or Antigravity login pick up a login refreshed on the Hub's Mac while they run, instead of failing with a revoked token.

## [0.35.0] - 2026-10-15

### Changed

- Conversations accept the new background gradients chosen in Noodle and on iPhone.
- The Usage window's bot menu shows each bot's icon beside its name.
- The Usage chart's day breakdown stays inside the chart instead of running off the top of the window.
- On voice calls, bots on the Hub introduce themselves by their own name and speak from their description and backstory, instead of calling themselves Codex.

## [0.34.0] - 2026-10-14

### Added

- Bots on the Hub can stop a computer assigned to them when they are done with it. This needs the Noodle Computer update released alongside.
- A bot on the Hub that starts a computer and then leaves it unused is reminded to stop it: after it has run for 30 minutes with nothing using it for 15. This needs the Noodle Computer update released alongside.

### Changed

- The Hub connects calls to the bot's voice itself, and Macs and iPhones send and receive a call's audio over their Hub connection. Calling needs the Noodle and iPhone app updates released alongside.
- Bots on the Hub know their own name and description, not just their backstory.
- Bots on the Hub say they are on a slow request and keep answering messages while it runs, using their harness's background tasks where it has them, instead of going quiet until it finishes.
- A bot made on the Hub introduces itself as soon as it is ready, and the starter team introduces themselves in their group. This needs the Noodle and iPhone app updates released alongside.

### Fixed

- A Codex bot on the Hub whose request fails, for example after a network timeout, answers the next message instead of staying stuck until Kick.

## [0.33.0] - 2026-10-14

### Fixed

- A long list in Settings → Groups shows its scroll bar again.

### Changed

- Settings → Companions lists Noodle Applet first, then Computer and Browser.

## [0.32.0] - 2026-10-13

### Added

- Bots keep the work you ask them to keep doing in their own assignments file, and every heartbeat does the next round of each item. Bots move such work there from their preferences the next time a heartbeat finds it.
- Phones can ask an idle bot to organize its own files, as Organize does in Noodle.
- Phones show pictures, videos and PDFs in conversations from small previews the Hub makes, instead of downloading each whole file.

### Changed

- A noodlet opened on a phone no longer waits for the Hub to pack its files before the phone knows whether it changed, so a phone can start the version it has at once while the new one downloads.

### Fixed

- Bots no longer settle into only checking their inbox on every heartbeat after a long run of quiet ones; each heartbeat now names the work to do.
- Restricted Muse Code bots start again. Muse Code 1.4.4 and later stopped with "Agent Definition filesystem source failed".

## [0.31.0] - 2026-10-13

### Added

- Bots can set repeating wake-ups on a cron schedule, such as every weekday at nine, for work you ask them to do regularly. A repeating wake-up keeps coming back until the bot cancels it, at most once every five minutes.
- Bots get a built-in skill for keeping their preferences and memory files: a new instruction replaces the one it supersedes, checks that found nothing are not logged, and long files get compacted.

### Fixed

- On a heartbeat, a bot you asked to keep doing something, such as a daily search, does the next round in full instead of stopping after a quick look.

## [0.30.0] - 2026-10-12

### Added

- Bots can schedule their own wake-ups, with a note on what to do then, to come back to work they are waiting on. At most three wait at once, and a bot that has woken itself twelve times in a row waits until someone writes to it.

### Changed

- Settings → Bots shows when each bot was last active instead of when it last had a heartbeat. A busy bot rarely needs a heartbeat, so the old time made active bots look neglected.
- After a bot sends a message, Messenger tells it whether unread messages are still waiting, or asks it to finish anything it left open, so bots follow up instead of stopping after one reply.

## [0.29.0] - 2026-10-12

### Added

- Inkbox can be added as a tool.

### Fixed

- A Codex bot on a voice call can save files and run its tools again. Once Codex had restarted, every command it tried during a call was blocked.
- A sheet can no longer get stuck on screen after the window it belonged to has gone. Its buttons did nothing and only quitting removed it; such a sheet now closes on its own.

## [0.28.2] - 2026-10-12

### Fixed

- Settings and sheets no longer bounce when you scroll them while everything already fits; only content taller than the window scrolls.
- A bot no longer stops partway through its work when the Mac runs low on memory. macOS was closing the helper that runs bots, which ended the bot's current reply.

## [0.28.1] - 2026-10-11

### Fixed

- **Choose Harnesses** turns harnesses on and off again when you press Done; the choices were being dropped.

## [0.28.0] - 2026-10-11

### Added

- Kling can be added as a tool.
- Image Generation, a built-in tool that makes pictures on the Hub, from a description or by reworking a picture. Download Stable Diffusion XL models and pick the default in Settings > Tools; people turn it on for their bots from their devices.
- Apple Intelligence bots can use TensorFold on the Hub's Mac, added in Settings > Harness > Apple Intelligence > Remote Models. The API key is optional.

### Fixed

- Noodle Hub no longer holds up its window while devices load conversations, and no longer re-reads every attachment each time.
- Opening Settings no longer reads every installed harness in full again to check its signature; a harness is checked again once it changes.

## [0.27.0] - 2026-10-10

### Changed

- Sheets that change size hide their content while they resize, animate to the new size and fade the content back in, as Settings does, and never grow taller than the screen; taller content scrolls, with the scrollbar clear of the rounded corners.
- Settings never grows taller than the screen; a tall tab scrolls.
- Noodlet games can put Shift, Control and Alt on controller buttons, and let a button press a key the stick also uses, such as gas on a trigger while the stick steers.

### Fixed

- Noodle Hub no longer reads every conversation from disk every second, and checks what changed for devices without holding up its window.
- Sound in noodlets that play it through an audio worklet, as many web games do, now plays instead of failing to start.

## [0.26.0] - 2026-10-10

### Changed

- Switching tabs in Settings hides the old tab while the window resizes, then fades in the new one once the window has its size, as in Safari.

### Fixed

- **Choose Harnesses** applies its choices when it closes, so the Settings window no longer resizes and moves it while harnesses are turned on and off.
- Noodle Hub no longer reads every bot from disk every second, which kept it busy while idle.

## [0.25.0] - 2026-10-09

### Added

- **Settings → Harness → Choose Harnesses…** turns harnesses on and off. A harness that is off is not lent to anyone, whatever their plan, and its bots do not start. New Hubs start with Codex, Claude Code, Muse Code and Grok Build; Hubs that already ran keep every harness on.

### Changed

- Talking to a Noodle Hub is quicker: the app keeps one connection open and sends everything over it, instead of connecting again for every request. Live views keep a connection of their own.
- Bots can no longer share a noodlet that has no preview; they are told to present it first, so its card shows a picture instead of a plain icon.

### Fixed

- Changes made just as the app connects to a Noodle Hub, such as a conversation pinned on another device, are no longer missed.
- Bots no longer miss new messages because their app never showed them how to read Messenger: each wake-up now points them at the Messenger guide. Thanks to Brad Hallett for finding this.

## [0.24.0] - 2026-10-08

### Changed

- Games bots make can read game controllers directly on iPhone and iPad too, with analog sticks and one controller per player.
- Games bots make keep themselves smooth on phones and TVs, lowering their resolution while they run slowly.

## [0.23.0] - 2026-10-08

### Added

- Devices watching a noodlet live hear when it is still starting or too busy to respond, even on a slow link.
- Play on a phone shows every game bots shared under Games, including ones never opened on the phone.
- Reactions travel both ways between people and a bot that runs on its owner's Mac.
- Chat effects bots send wait on the Hub until one of the person's devices shows the conversation, for up to a day, and play there once.

### Fixed

- Noodlets bots share now show their preview instead of a plain icon: bots are told to present a noodlet rather than just attach it, and a bot that attaches one with no preview is told to present it.

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
