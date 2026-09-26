# Changelog

## [Unreleased]

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

- Refuse devices that are not paired before reading anything they send. A new device can only reach the Hub while an invitation is open, and then only to join. A removed device is disconnected at once.
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
