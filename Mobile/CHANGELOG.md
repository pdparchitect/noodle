# Changelog

## [Unreleased]

## [0.24.0] - 2026-10-07

### Added

- Make your own spaces with any bots and groups from all your Hubs. Tap the title and choose New Space, or touch and hold a conversation and choose Spaces, which also adds it. Each space keeps its own pins, and bots and groups made in a space join it. Your spaces are the same on your iPhone, iPad and Mac through iCloud.

### What to Test

- Tap the title, choose New Space and name it: the empty space shows. Touch and hold bots from two different Hubs, choose Spaces and tick the space: both show there, and nowhere else changes. Pin one in the space: it is pinned there only, not in All or in its Hub's space.
- In your space, make a new bot or group: it shows in the space. Untick a pinned bot under Spaces: it leaves the space and its pin there.
- Tap the title for Rename Space and Delete Space. Deleting asks first, and its bots and groups stay in All. Quit and reopen the app: it opens on the same space with its members and pins.
- Signed in to the same iCloud account on two devices, make a space on one: it shows on the other, with its members and pins, within moments (on the Mac, once you switch to Noodle). Rename, change and delete it on either side: the other follows.

## [0.23.0] - 2026-10-07

### Added

- Tap the title to choose All, or one joined Hub's space with only its bots and groups. Pins in a Hub's space are kept on the Hub, so they are the same on all your devices; pins in All stay on this phone.
- In a Hub's space, New Bot and New Group start on that Hub, so they show there. You can still choose another Hub.

### Changed

- The bots and groups of every Hub you joined share one list. Hubs no longer switches between them: tap a Hub there for its details.

### What to Test

- Join two Hubs: both Hubs' bots and groups show in one list, each marked with its Hub. In ••• > Hubs, tapping a Hub opens its details, and there is no Show All Hubs Together.
- Tap the title and choose a Hub: only its bots and groups show, without the Hub's name on each row. Pin one there: it shows pinned in that Hub's space in Noodle on the Mac too, but not in All. Unpin it on the Mac: it unpins on the phone. Pins made in All stay on the phone only. Quit and reopen the app: it opens on the same space with its pins.
- Pin two bots in a Hub's space: they keep the order you pinned them in, on the phone and on the Mac, whichever has the newer message. Leave the Hub and join it again: the space and its pins come back.
- Join a Mac through its Settings → Hub and choose its space: the Mac's pins show, and pinning or unpinning on either side shows on the other.

## [0.22.0] - 2026-10-06

### Added

- Tables in messages show as a card between the text around them. Tap it to open the whole table in a sheet, tap a column header to sort it, and copy or share the table as CSV. Notifications, pinned bubbles and the chat list leave tables out.
- Settings has Haptics for On-Screen Controls, off by default. When on, the on-screen game controls tap as you press a button and tick as a d-pad or stick moves to a new direction.

### Fixed

- Switching Speaker repeatedly during a call no longer leaves extra microphones running or applies an earlier switch after a later one. Ending a call also releases microphones that finish starting afterwards.
- Mute chosen while a call connects stays on when the microphone starts.
- Calls keep their microphone and sound when opening or closing a noodlet, playing a voice message, or leaving a conversation.
- The call timer and connected chime wait for the phone's voice connection and playback to be ready. A playback failure ends the call with an error instead of leaving it silently connected.

### What to Test

- Ask a bot for a table, for example "compare three phones in a table". The table shows as a card with its column names and row count, between the text around it. Tap the card: the whole table opens in a sheet. Tap a column header to sort it, again to reverse, a third time for the original order. Copy as CSV and Share CSV are in the sheet's menu.
- Lock the phone and have a bot reply with a table: the notification shows the text around the table, or "Sent a table" if there is nothing else.
- Start a Codex call and immediately tap Mute: the bot must not hear you until you unmute.
- Switch Speaker on and off several times, then speak: the bot should hear one voice and the final speaker choice should apply. End the call while it is connecting or switching speakers: the microphone indicator should turn off.
- During a call, play a voice message, open and close a noodlet, and visit another conversation: the call should keep hearing you and playing the bot's voice.
- Check that the timer and connected chime start only once the phone's voice connection is ready; a playback failure should end the call with an error.
- Turn on Settings > Haptics for On-Screen Controls and play a noodlet game with on-screen controls: each button press taps, a softer tap on release, and sliding along the d-pad or stick ticks on each new direction. Turn it off: nothing is felt.

## [0.21.0] - 2026-10-05

### Added

- You can call your Codex bots on the Hub, and Codex bots shared with you: tap the phone in a conversation's top bar and talk things through. The bot answers aloud and works on what you ask. Calls start on the earpiece, where the bot sounds clearest; Speaker switches to the loudspeaker. A bar at the top shows the call's time with Speaker, Mute and End, and the conversation stays open, so you can type and share files while you talk; the call hears about them. What is said shows in the conversation as short transcript blocks; tap one to read all of it. Each bot's voice is chosen under Voice in its editor, with a sample of each to hear.

### What to Test

- Open a conversation with one of your Codex bots and tap the phone. Allow the microphone. After a short wait you hear a chime and the bar starts counting: ask the bot something and hear it answer.
- During the call, type a message or share a photo. The bot hears about it, and the transcript splits around it in the conversation.
- The call starts on the earpiece: hold the phone to your ear and the bot sounds clear. Tap Speaker: it moves to the loudspeaker without the bot hearing itself, though it sounds more like a phone line. Tap Speaker again to go back.
- With AirPods connected, the bot sounds clear in them.
- In a Codex bot's editor, tap Voice: tap each voice to hear it, pick one and save. The next call uses it.
- Tap Mute: the bot stops hearing you. Tap End: the call ends and its card shows how long it lasted.
- Lock the phone during a call: the call should keep going.
- Call a Codex bot someone shared with you: it works the same, and the call shows only in your conversation with it.
- Bots on other harnesses show no phone.

## [0.20.0] - 2026-10-05

### Added

- Your picture on a Hub can be changed: tap it in that Hub's details, under Hubs. Take a photo, choose one or create an image, or pick a symbol or your initials on a colour. Everyone on the Hub sees it, and Sharing in a bot's editor and an admin's Users list show each person's picture.

### Changed

- Sharing in a bot's editor shows everyone on the Hub as pictures to tap, with a line saying who can talk to the bot. The Sharing row says how many people the bot is shared with.

### Fixed

- Noodlets a bot shares show their own names in the conversation, under Shared and in the game menu, instead of all being called Noodlet.

### What to Test

- Open ••• > Hubs, tap ⓘ beside the Hub, then tap your picture. Take a photo: the camera lets you fit it into a square. Tap Done; the new picture shows at once, and on your other devices within a minute.
- Pick a colour and a symbol, then your initials, tapping Done each time. On someone else's device on the same Hub, open Sharing in one of their bots' editors: your picture matches.
- As an admin, open Users in the Hub's details: each person shows their picture, or their initials if they chose none.
- Open a Hub bot's editor and tap Sharing: tap someone's picture to share the bot with them and again to stop; the line under the pictures says who can talk to the bot, and the Sharing row shows the count.

## [0.19.0] - 2026-10-04

### Added

- Bots on a Hub can be shared with other people on it, from Sharing in the bot's editor. Each person talks with the bot in a conversation of their own. A bot someone shared with you is for talking with only: it cannot be edited or archived, and is not offered for groups. Tapping its name, or Change Background… when holding its row, sets your conversation's background.
- Admins of a Hub can manage its users from the phone: Users in that Hub's details, under Hubs, lists everyone. Add someone with +, and tap a person to change their plan and whether they can pair devices, rename them, invite or remove their devices, or remove them. Admins are listed but changed only on the Hub.
- Games can show a thumbstick on the screen instead of a d-pad: its knob follows your thumb, and it steers in eight directions like the d-pad.

### Changed

- Leave Hub also removes the phone from the Hub's devices. The Hub is gone from the phone at once; if it cannot be reached, the phone tells it the next time it can.

### What to Test

- Leave a Hub: it disappears from Hubs at once, and the phone disappears from Users on the Hub, also when the Hub was off while you left and is turned on later.
- On the Hub, turn on Admin for yourself in Settings > Users. On the phone, open ••• > Hubs, tap ⓘ beside the Hub, then Users: add someone, invite a device for them, change their plan, then remove them.
- Without Admin, Users does not appear.
- On the phone, open a Hub bot's editor, tap Sharing and tick someone else on the Hub. On their device the bot appears; they can talk with it, tapping its name offers only its background, and holding its row offers Pin and Change Background… Untick them: the bot disappears from their device.
- Ask a bot for a twin-stick shooter played with thumbsticks and open it on the phone: both sticks show as rings with a knob that follows your thumb and springs back when you let go, and the ship moves and aims in eight directions.

## [0.18.0] - 2026-10-03

### Added

- While a game plays on the TV and a game controller covers all its buttons, the phone shows the connected controllers and their batteries instead of a blank screen.
- In a noodlet, the controller's View button (Create on PlayStation, − on Switch) shows the conversation's other noodlets, on the TV while it plays there: move with the d-pad or stick, press A to switch to one, or choose Close Game. B or View again goes back to the game.

### Changed

- Profiles under ••• in the chat list is now Hubs, as it lists the Hubs you joined.

### Fixed

- The phone no longer dims and locks while a game controller is connected to an open noodlet, or a game plays on the TV: controller presses do not count as touches, so it used to go to sleep mid-game.
- Games make sound in Silent Mode, as videos do. They were silent with Silent Mode on, on the phone and on the TV.
- Games play on the TV on iOS 27: with Screen Mirroring on, Show on TV said no TV was connected and the TV kept mirroring the phone. Until a game is open, the TV now mirrors the phone as usual. Needs iOS 27.
- Noodlets run on the phone have sound: a game played with the on-screen controls was silent, as was any noodlet with the ring switch set to silent. Music playing in another app carries on alongside.

### What to Test

- Turn on Screen Mirroring and open a game noodlet: it plays on the TV, and the phone turns sideways and shows only the controls.
- Tap Show on iPhone: the TV mirrors the phone again and the game carries on there without starting over. Tap Show on TV: it goes back to the TV.
- Close the game: the TV mirrors the phone again.
- Open a game the Hub streams: it plays on the TV the same way.
- With a game on the TV, press a button on a paired controller: the phone shows the controller, its logo and its battery. Disconnect it: the on-screen controls come back.
- In a conversation with several noodlets, open one and press a paired controller's View button: the noodlets show over it, on the TV while it plays there. Pick another with A: it opens on the TV without touching the phone. Open the menu again and choose Close Game: the game closes and the TV mirrors the phone. Press B in the menu: the game carries on.
- In that menu, each noodlet shows its picture and name, as in the conversation.
- Play a game with only a controller for a few minutes without touching the phone: the screen stays on. Close the game: the phone dims and locks as usual again.
- Turn Silent Mode on and play a game with sound: you hear it on the phone, and on the TV while casting.
- With the ring switch set to silent, open a noodlet with sound on the phone and play it with the on-screen controls only: you hear it. Play music in another app first: both play together, and the music carries on after you close the noodlet.
- In the chat list, tap ••• and choose Hubs: it lists the Hubs you joined, each with your name on it.

## [0.17.0] - 2026-10-03

### Added

- Play games on a TV: with Screen Mirroring on, or a TV connected by cable, a noodlet with game controls plays full screen on the TV and your phone becomes its controller. Show on TV and Show on iPhone move it between the two.

### What to Test

- Turn on Screen Mirroring to an Apple TV or AirPlay TV: the TV shows the Noodle wordmark instead of a copy of the phone.
- Open a game noodlet: it plays on the TV, and the phone turns sideways and shows only the controls. Play a little: the TV answers the phone's buttons.
- Tap Show on iPhone: the game comes back to the phone without starting over. Tap Show on TV: it goes back to the TV.
- Close the game: the TV shows the wordmark again. Stop Screen Mirroring with a game open: the game carries on on the phone.
- Open a game the Hub streams: it plays on the TV the same way, sharp at the TV's size.
- With no TV connected, tap Show on TV: it says how to connect one.
- With a game controller paired to the phone and a game on the TV: press a button on it and the phone hides the controls the controller has.

## [0.16.0] - 2026-10-03

### Changed

- A conversation's background is kept on the Hub, so it is the same on your phone and your Macs, and a background video chosen on a Mac plays here too. Backgrounds chosen on this phone before are gone. Needs the matching Noodle Hub, or Noodle on a Mac serving as a Hub.

### What to Test

- Choose a photo as a conversation's background: the same conversation on the Mac shows it within a few seconds. Change it on the Mac to a gradient: the phone follows.
- On the Mac, choose a video as a conversation's background: it plays, silently, behind that conversation on the phone. With Reduce Motion on, the phone shows a still picture.

## [0.15.0] - 2026-10-03

### Added

- Archive a bot or group by touching and holding it in the list: it keeps everything but stops running and leaves the list, for all your devices. Bring it back from Archived in the Hub's profile, under Profiles. Needs the matching Noodle Hub, or Noodle on a Mac serving as a Hub.

### What to Test

- Touch and hold a bot, choose Archive Bot: it leaves the list. In a group with it, its picture leaves the group's and it is no longer offered after @.
- Open Profiles and the Hub's details, then tap Archived: the bot is in the list. Tap Unarchive: it is back among your chats and answers again.
- Archive every bot in a group, then open the group: the message field says every bot in it is archived and cannot be typed in.
- Archive a group, then unarchive it from the Hub's profile: its messages are all still there.
- In Archived, tap a bot or group: its conversation opens to read, and the message field says it is archived.

## [0.14.0] - 2026-10-02

### Changed

- … in a conversation opens a Shared sheet with titles and previews for choosing a computer, browser tab or noodlet.
- Create Image in a bot's picture starts from an avatar portrait with the bot's name and description, instead of an empty Image Playground.
- Create Image in a bot's picture opens on Illustration and no longer suggests people from Photos, as on the Mac.
- Create Image for a background opens on Illustration, starts from the photo in use, no longer suggests people from Photos and makes an image the shape of the screen instead of a square, as on the Mac.

### What to Test

- In a conversation with shared noodlets, tap …: Shared shows their titles and previews; tap one to open it. Update the Hub too to get noodlet titles.
- Open a conversation and tap the message field: the field sits a little above the keyboard, not on it, and drops back level with Search when the keyboard goes.
- Scroll a long conversation to the end, go back to the list and open it again: it opens at the end, the last message just above the message field.

### Fixed

- Shared noodlets showed only “Noodlet”, making them impossible to tell apart.
- With the keyboard up, the message field sat right on the keyboard.
- A conversation could open short of its end or past it, even when you had left it at the end.

## [0.13.0] - 2026-10-01

### What to Test

- Open a conversation: the message field sits at the same height as Search in the list of bots.
- Tap More in the list of bots: New Bot shows a person with a plus, like New Group shows people.
- In a conversation where a bot shared a computer, browser or noodlet, tap … at the top: each one shows once, newest first, and opens live from there.
- Tap a bot's name at the top of its conversation: New Session is near the bottom of its settings, and Kick too when the bot has failed.
- Touch and hold each pinned bot or group in turn: each shows its own menu, Edit Bot for a bot and Edit Group for a group.
- React to one of your own messages and to a bot's: the reaction sits on the top right corner of both.
- Pair with a Hub whose Mac is asleep, or with Wi-Fi off: tap Help Me Connect under the message and check that Your Hub shows which ways answer and the suggestions fit, then wake the Mac or turn Wi-Fi on and tap Try Again.
- Pair with a Hub whose Mac is asleep: the Pair button shows which Hub it is connecting to, says Still trying after a few seconds, and Cancel stops at once. Do the same from Add Hub in Profiles.
- Turn off Local Network for Noodle in Settings and pair again: Help Me Connect asks you to turn it on, and Open Settings goes straight there.
- Open a Hub noodlet that uses the camera or your local network: it asks once, then not again. Settings lists it; swipe it away and it asks the next time.
- Ask a bot to share a web page as a link: it shows the page's picture, title and site, like a link in a message, and tapping it opens the page.
- In a bot's settings, add a new computer and a new browser: each is named for the bot, such as Chloe’s Computer, and changing the computer's kind keeps the name.

### Added

- Help Me Connect, when pairing cannot reach the Hub, tries each way to it, home Wi-Fi, Tailscale and the internet, shows which answer, and suggests what to try, such as joining the Hub's Wi-Fi, allowing Local Network or opening Tailscale.
- … in a conversation lists the computers, browsers and noodlets shared there, for opening again without scrolling back, as Shared does on the Mac.

### Changed

- A new computer or browser is named for its bot, such as Chloe’s Computer.
- Pairing shows the Hub it is connecting to and can be cancelled, instead of a bare Joining… spinner.
- New Session and Kick moved from … to the bot's settings, opened by tapping its name.
- Reactions sit on a message's top right corner, on your messages too, as on the Mac.
- New Bot in More shows a person with a plus instead of a bare plus.
- A web link a bot attaches shows the page's picture, title and site, like a link in a message, instead of a .webloc file.
- A noodlet from a Hub asks once before it uses the camera, microphone or devices on your local network, such as a TV, and Settings lists what each was allowed; swipe to take it back. Any noodlet reaches the internet without asking.

### Fixed

- Touching and holding any pinned bot showed the first pinned one's menu, so Unpin and Edit acted on the wrong one.
- The message field sat higher than Search in the list of bots.

## [0.12.0] - 2026-10-01

### What to Test

- Open a noodlet a bot shared: it runs on this iPhone, and responds at once to taps and typing. What it saves is still there when you open it on your Mac.
- Tap Run on Hub to watch it live from the Hub instead, then Run on iPhone to bring it back. Open it again later: it comes up where you left it.
- Touch and hold a noodlet's card and choose Open on iPhone or Open on Hub: it opens there, and next time too.
- Open a noodlet that uses the microphone or camera: it runs on this iPhone and asks for it here, and Run on Hub is not offered.
- A game with controls shows them over the noodlet; a game controller in hand plays it too.
- In a noodlet running on this iPhone, tap the keyboard button and type: a game gets the keys, and a field the noodlet selected gets the text.
- Open a game made to fill the screen: it takes the whole screen without the status bar, cannot be scrolled or zoomed by accident, and one made for landscape turns the phone sideways until you close it.
- Open a noodlet a second time: it comes up without downloading again. After the bot changes it, it downloads once more.
- Open a group: each bot's picture sits beside the last of its messages in a row, with its name above the first.

### Added

- Noodlets run on this iPhone instead of streaming from the Hub, which is faster and smoother. Run on Hub switches to watching one live from the Hub, and Noodle remembers the choice for each noodlet. Touch and hold a noodlet's card to choose before it opens. A noodlet that uses the camera, microphone or screen always runs on this iPhone. The Hub needs its latest version.
- In a group, each bot's picture shows beside its messages, as in Messages.

### Fixed

- A game's on-screen controls show over a light page too, where they were white on white.
- With the phone sideways, a game's on-screen controls keep clear of the Dynamic Island and the home bar instead of sitting under them.

## [0.11.0] - 2026-09-30

### What to Test

- Open a conversation where a bot sent a web link: a card with the page's picture and title shows under the message. Quit and reopen Noodle, or turn on Airplane Mode: the card is still there.
- A link to a page that shares no preview still gets a card with the site's name.
- With Stack chosen for files, open a message with a noodlet and several pictures: the noodlet sits whole above them, and only the pictures overlap.
- Press return in an empty message field, go back to the list and open the conversation again: the field is empty, says Message, and is as tall as the plus beside it.
- Open a computer's live view, touch and hold a window's title bar, then move: the window follows and stays where you let go.
- Pinch with two fingers to zoom into a computer or browser; move both fingers to look around, and pinch out to see it whole again. Taps land where you tap.

### Added

- Touch and hold, then move, to drag in a computer or browser live view, as with a mouse.
- Pinch to zoom into a live view, and move two fingers to look around it. The picture sharpens once you let go.

### Changed

- Link cards look as on the Mac, and are kept on this iPhone for a week, instead of being fetched again each time Noodle opens. After a week they are fetched again, and deleting a conversation removes its cards.
- Stack overlaps only files you can swipe through together, as on the Mac; noodlets, browsers, computers and voice messages sit side by side above them.

### Fixed

- A link to a page that shares no preview showed no card at all.
- A message field left with only blank lines no longer comes back taller than the plus beside it, without its placeholder.

## [0.10.0] - 2026-09-30

### Changed

- A live view that falls behind on a slow connection picks up again from a small picture built on what it already shows, instead of a full new picture that is about 40 times larger and blurry for its first moments.
- Live views start live on a slow connection: the first picture comes at a moderate rate and more follows as soon as the device confirms it can take it, instead of the first seconds arriving late.
- Brief wobbles on Wi-Fi no longer make live video lighter than the connection allows.

### Fixed

- Live views are sent at the size of their window. The window's size could go unsaid when it appeared before its connection opened, so video came larger than it needed to be.

## [0.9.0] - 2026-09-29

### What to Test

- Type a message of several lines, or press return a few times: the field grows over the conversation, and the conversation and its scroll bar stay where they are.
- Turn on Airplane Mode and send a message: it says Sending… for a while, then Not delivered in red with a red mark beside it. Turn Airplane Mode off within a few seconds instead, and it goes through by itself.
- Tap the red mark, or hold the message: Try Again sends it, Edit and Send puts it back in the field with its files, and Delete removes it. Once anything newer is in the conversation, Try Again is gone and the message is never sent by itself.
- Quit and reopen Noodle with a message that did not go through: it is still there, still marked.
- Make a new group, or open a group's info: each bot in Members shows its description under its name.
- Pull the list of conversations down until it clicks, and keep holding: the word stays in the gap above the list and does not jump over the pinned bots, also after you let go.

### Changed

- Choosing a group's bots shows each bot's description under its name.
- Live views ask for a fresh picture whenever they cannot show the next one, as after Noodle was in the background. Newer Noodle Browser, Computer and Applet send one only when asked, which keeps video from stuttering every two seconds on a slow connection.
- Live views stay live on a slow connection. They tell the Hub which pictures have arrived, so it sends less as soon as pictures start arriving late, instead of letting them pile up in the network and show a second or more behind. Update the Hub as well.

### Fixed

- Adding lines to a message no longer moves the conversation or its scroll bar.
- Pulling to refresh past the click no longer makes the word jump and draw over the pinned bots and the first conversations.
- A message that does not go through is tried again by itself while it is still the newest, and otherwise stays marked Not delivered, with Try Again, Edit and Send, and Delete, instead of an error under the conversation that stayed until the next message.

## [0.8.0] - 2026-09-29

### What to Test

- Ask a bot to make a simple game with arrow keys and a jump button, then open the game from its message: a d-pad and buttons show over it instead of the keyboard, and holding one keeps moving. Needs Noodle Applet, the Mac or Hub on the next update.
- The controller button at the top hides and shows the controls; the keyboard button beside it still types into the game.
- Pull the bots list down slowly: the Noodle word writes itself as you pull, is whole when letting go refreshes, and goes once the list has refreshed.
- React to a message: the reaction sits over the bubble's top corner, as in Messages, and tapping it takes yours back. On a reply with a file, it marks the text, which now comes before the file, as on the Mac.
- Connect a game controller: it plays the game, and once you press something on it, only the buttons it has no room for stay on the screen.

### Added

- Games your bots make show a controller over the live view instead of the keyboard, and game controllers play them too.

### Changed

- Pulling a list to refresh writes the Noodle word instead of showing a spinner.

### Fixed

- Reactions sit over the message's corner, as in Messages, instead of on their own line under it, and mark the text rather than a file sent with it. Reacting no longer moves the conversation.
- A message's text shows before its files, as on the Mac.
- Reaching a Noodle Hub no longer sometimes waits 10 seconds and fails with "The Hub did not answer in time" when a Hub has recently started or stopped on the same Mac.

## [0.7.0] - 2026-09-29

### What to Test

- Pin a bot, then ask it to set its status with Messenger (for example, "set your status to Reviewing PR 42"): the status shows in a bubble over its circle. Needs the Mac or Hub on the next update.
- While a pinned bot has a reply you have not read, its bubble shows the start of that reply in bold instead. Open the conversation and the bubble goes back to the status, or away.

### Added

- Pinned bots show a bubble over their circle with the start of an unread reply, or else the status the bot set.

## [0.6.0] - 2026-09-29

### What to Test

- Pull down on the bots list and type in Search: only bots whose name, description or conversation match are listed, in one list without the pinned circles. Accents and capitals do not matter.
- Touch and hold a bot in the list: a menu offers Pin and Edit Bot…. On a pinned circle it offers Unpin and Edit Bot….
- In a conversation, tap the … button at the top right: New Session asks first, then starts the bot with a fresh context. When the bot has failed, Kick is there too and starts it again, asking first when the Mac or Hub would. Try it with a bot on your Mac and one on a Noodle Hub.
- With a phone paired to a Mac, create or edit a bot: Harness lists the harnesses installed on the Mac and their profiles, by name, and Model lists all of the chosen harness's models. Needs the Mac on the next Noodle update.
- Create or edit a bot and choose a model with reasoning efforts, such as a Codex model: Effort appears under Model and offers Default and the model's efforts. Switching to a model without the chosen effort resets it. Needs the Mac or Hub on the next update.
- Paired with a Mac serving your devices (Settings > Hub in Noodle): create a computer and a browser, add a tool and sign it in, then give them to a bot. They appear in Noodle on the Mac too, and the bot can use them.
- Paired with a Mac serving your devices, edit a bot and change its model or effort: the bot restarts, and its next reply comes from the new model. Needs the Mac on the next Noodle update.
- Create or edit a bot and open Harness: a harness lent under a profile shows its name with the profile on a second line; check that a long profile, such as an email address, reads cleanly. Once chosen, it reads on one line, such as Codex · you@example.com.
- Open a conversation: the Message field and the + beside it are as tall as Search on the bots list.
- Close a game noodlet's window on the Mac, such as a canvas game, then watch it from the phone: it plays and moves, rather than showing only its background. Needs the Mac on the next Noodle Applet update.
- With no Browser window open on the Mac, watch a browser tab from the phone that plays a video or animation: it keeps moving. Open another tab from the phone and it moves too. Needs the Mac on the next Noodle Browser update.
- Send a message with a web link: in your blue bubble the link reads in white and underlined.
- Tap a web link in a conversation: it opens in a preview inside the app, whose Safari button continues in Safari. Turn off Preview Web Links in Settings, from the … button on the bots list, and it opens in Safari straight away.
- In Settings, from the … button on the bots list, choose Wrap, Vertical or Stack for Attachments, then open a message with several pictures: they sit side by side, one below another, or overlapping.
- Stop Noodle on the Mac or Hub your phone is paired with, then pull down on the bots list: its bots' dots turn grey, and in Profiles, from the … button, the Hub reads Not connected. Start it again and pull down: the dots show each bot's state again.
- Tap … on the bots list, then New Group: name it, pick some bots and tap Create. The group appears in the list and on the Mac. Send a message: its bots answer, each named above its replies.
- Make a group in Noodle on the Mac or Hub: it appears on the phone. Touch and hold it and choose Edit Group…, or tap its name in the conversation, to rename it, change its bots, set its background or delete it.

### Added

- Search the bots list by name, description or what was said, as on the Mac.
- Touching and holding a bot shows a menu with Pin or Unpin and Edit Bot….
- Kick and New Session, in a conversation's … menu, start a stuck bot again or give it a fresh context, as on the Mac.
- New Tool lists the services your Hub offers, with search, and adds the one you tap and signs it in. Your own MCP server is under Custom MCP Server at the end of the list.
- Effort, in the bot editor, sets how hard the bot's model reasons, when the model offers a choice.
- Web links open in a preview first, as on the Mac, with a button to continue in Safari. Preview Web Links, in Settings, turns this off.
- Settings, in the … menu of the bots list, holds options for the whole app.
- Attachments, in Settings, lays out a message's files side by side, one below another or overlapping, as on the Mac.
- Groups: see, create, edit and delete conversations with several of your bots, as on the Mac.

### Changed

- Harness lists a profile under its harness's name, and shows the chosen one on a single line.
- Profiles shows whether each Hub is connected, and the bots of a Hub that is not show as offline instead of their last known state.

### Fixed

- The Message field in a conversation is as tall as Search on the bots list.
- A link in your own message is no longer lost against the blue of its bubble.
- Noodle Hub is tried again for a few seconds when it is starting up or the network is settling, instead of failing at once.
- A bot's harness shows its name rather than its internal identifier when the Hub no longer lends it under the same profile.
- Switching a new computer between Shell and Desktop changes its name to match, unless you typed your own.
- On a Mac serving your devices, creating or changing tools, computers and browsers no longer fails with "Manage tools, computers and browsers in Noodle on the Mac." The phone works on the Mac's own ones.

## [0.5.0] - 2026-09-28

### What to Test

- Open a conversation: its latest message sits just above the message field, with no gap under it, and the conversation does not sit shifted to the side before you first scroll.
- The app icon on the Home Screen is Apple's system blue, matching the Mac apps.
- Swipe right on a bot and tap Pin: it moves to a circle above the list, as in Messages. Tap the circle to open the chat; touch and hold it to unpin.
- Touch and hold a message: as in Messages, the conversation blurs, the message lifts, reactions float above it and Copy below. Tap a reaction to add or take it back, or tap outside to close. Try messages near the top and bottom of the screen, and a long one.

### Changed

- The app icon uses Apple's system blue, the same flat blue as the Noodle Mac apps.
- Touching and holding a message lifts it with reactions above and actions below, as in Messages.

### Fixed

- A conversation no longer opens scrolled past its end and slightly to the side.

## [0.4.0] - 2026-09-28

### What to Test

- Open an invitation link on the phone: it asks Join this Hub? with the Hub's key before joining. Compare the key with the one under the invitation on the Hub; Cancel joins nothing.
- In a Hub's profile, Hub Key matches the key under its invitations.
- Create or edit a bot: after choosing a harness, choose its model. With a plan that limits models, only those are offered.
- In your profile, tap Pair Another Device: scan its QR code with another phone or iPad, or copy or share the link. Once it expires, tap New Invitation.
- On the Hub, in Settings > Users, turn off Can Pair for your user: Pair Another Device no longer shows after you pull to refresh your profile.
- In Tools, sign a connection in: its sign-in page still opens and the connection signs in.

### Added

- Choosing a bot's model from those your plan on the Hub allows.
- Pair Another Device, in your profile, shows an invitation for another of your devices to join your Hub, when the Hub allows it.

### Security

- A Noodle Hub can no longer show a sign-in page on its own. The app shows one only for a sign-in you started, and only if it is a web page.
- An invitation link opened on the phone, from a web page, message or the Camera app, asks before joining and shows the Hub's key. Scanning or pasting an invitation in Noodle still joins straight away.
- A Hub's profile and Pair Another Device show the Hub's key.

## [0.3.2] - 2026-09-27

### What to Test

- Tap a notification of a new reply: the app opens that conversation.

### Fixed

- Tapping a notification no longer closes the app.

## [0.3.1] - 2026-09-27

### What to Test

- Leave the app and have a bot reply: a notification arrives with the bot's name and its reply.

### Fixed

- Setting up notifications waits until the phone is registered for push, which CloudKit needs before it notifies it; before, CloudKit refused them.

## [0.3.0] - 2026-09-27

### What to Test

- Record a voice message and tap the cross to discard it, including just beside it.
- Open a shared browser, computer or noodlet and rotate the phone both ways: it stays open.
- Open a picture in a message with several files and swipe to the others.
- Read a conversation on your Mac: its unread dot on the phone goes away. Read one on the phone: it clears on your Mac.
- Pair a second phone or iPad: conversations you already read elsewhere are not unread there.
- Allow notifications, then leave the app and have a bot reply: a notification arrives with the bot's name and its reply, and tapping it opens the conversation. Several replies in a row leave one notification.
- With the app open, no notification arrives. Reading the conversation removes its notification.

### Added

- Notifications of new replies while the app is closed or in the background, with the bot's name and what it said. This needs a Hub from this release on.

### Changed

- Opening a picture or file from a message lets you swipe through the message's other files.
- Conversations you read on another device are read here too, and reading here clears them on your other devices. This needs a Hub from this release on.

### Fixed

- Tapping beside the discard button while recording no longer opens the picture or message behind it.
- The live bars scroll smoothly while recording instead of stuttering.
- Rotating the phone no longer closes a shared browser, computer or noodlet you are watching.

## [0.2.2] - 2026-09-27

### What to Test

- Tap the plus by the message field and send a photo, a file or a camera shot from the panel.
- Record and send a voice message.
- Open a conversation with many pictures: it should not jump while they load.
- Send a message, and scroll up while a bot replies: you stay where you are.

### Changed

- The message field is taller, as in Messages, and holds the microphone and send button. The plus opens a panel with Camera, Photos and Files that grows out of it.

### Fixed

- A conversation no longer jumps while pictures load: each keeps the room it needs from the start, on Hubs that send the picture's size.
- Sending a message scrolls the conversation down to it. At the bottom, a new reply scrolls into view from its first line; scrolled up to read, you stay where you are.
- Recording a voice message no longer closes the app.

## [0.2.1] - 2026-09-26

### What to Test

- Join a Hub whose bots have photo pictures: chats show at once and the pictures follow.
- Rename a bot that has a picture; the picture stays.
- Open the app to see the swirl write Noodle before Pair.

### Changed

- Noodle opens with a swirl that rises from the bottom of the screen and writes its name, then shows Pair.

### Fixed

- Connect to a Hub whose bot list or live views are large, such as bots with photo pictures, instead of stopping at “The message is too large.” Chats show at once and bot pictures follow, each fetched once and kept; editing a bot no longer sends its picture back.

## [0.2.0] - 2026-09-26

### What to Test

- You need an invitation to a Noodle Hub. Join it by scanning its QR code, pasting its link or opening the link on the phone.
- Chat with your bots: send messages, photos, files and voice messages, and react to replies.
- Make a bot with New Bot, then change its picture, background, tools, computers and browsers in its settings.
- Tap a browser, computer or noodlet a bot shares to use it live.
- Join a second Hub from Profiles and switch between them, or show them all together.

### Added

- Open a browser tab, computer or noodlet a bot shared: tap its card to see it live on the Hub's Mac, tap to click, drag to scroll, and type with the keyboard button. Turn the phone sideways to give it the whole screen. Its bot waits while you have it open. Cards show the latest picture of a noodlet and the latest lines of a computer's terminal.
- Give a bot tools, computers and browsers from its settings. Tools, Computers and Browsers list yours on the Hub; tap one to let the bot use it or not, + adds one, and swiping deletes it. A tool that needs signing in opens its sign-in page on the phone.
- Join your Noodle Hub from an invitation: scan its QR code, paste its link, choose a photo of the QR code, or open the link. Noodle then shows who you joined as, your plan and whether the Hub is connected, and can leave the Hub.
- Chat with your bots on the Hub. They are listed like Messages, newest conversation first; tap one to read the conversation and send messages, and replies appear as the bot writes them. The app opens on what it last saw, including the harnesses your plan lends, and catches up with the Hub in the background.
- Make bots on the Hub with New Bot in the … menu, choosing a name, a colour and one of the harnesses your plan lends. Tap a bot's picture at the top of its chat to edit or delete it. Profiles in the same menu lists every Hub you joined: tap one to show its bots, open its details to see who you joined as or leave it, or add another Hub with Add Hub. With Show All Hubs Together, the bots of every Hub share one list, each marked with its Hub, and New Bot asks which Hub to make it on.
- Send photos, videos, camera shots and files with the + button next to the message field. Pictures show in the conversation, other files as cards that open in Quick Look, and web links show a preview. Your latest message says whether it was sent and delivered.
- See which bots replied since you last opened their conversation: a blue dot marks them in the list.
- Long replies fold after eight lines with Read more. Unsent text stays in each conversation, and a copied image can be pasted into the message field.
- React to a message by touching and holding it, with the same twelve reactions as on the Mac. Reactions show under the message with a count, and tapping one adds or takes back yours. A dot on each bot's picture shows whether it is working, ready or failed, as on the Mac.
- Send voice messages with the microphone next to the message field. Speech is transcribed on the device as you talk, and the bot gets the transcript with the audio. Voice messages play in the conversation with their waveform; touch and hold one to read its transcript.
- Type @ and part of a bot's name to pick it from a strip above the message field, as on the Mac.
- Give each conversation a background in the bot's settings: one of the Mac's four presets, a photo, or an image made with Image Playground. Touch and hold a picture in a conversation to use it as the background. Backgrounds stay on this phone.
- Edit a bot's picture as on the Mac: a photo or Image Playground image, or one of the Mac's symbols on a colour.
- Pin bots to the top of the list by swiping right. Pins stay on this phone.

### Fixed

- The join sheet no longer repeats its heading.
- The unread dot in the list of bots sits evenly between the screen edge and the bot's picture instead of against it.

### Changed

- Conversations open on their newest messages and load earlier ones as you scroll back; card pictures fill in as they come into view.

## [0.1.0] - 2026-09-25

### Added

- Try an early placeholder of Noodle for iPhone and iPad. It shows the Noodle symbol and does nothing else yet.
