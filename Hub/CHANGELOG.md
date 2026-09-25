# Changelog

## [Unreleased]

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
