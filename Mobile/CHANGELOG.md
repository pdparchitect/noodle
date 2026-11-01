# Changelog

## [Unreleased]

## [0.52.0] - 2026-11-01

### Added

- Settings › Conversation List › Show chooses the line under each name, as on the Mac: Latest Message, Description, or Status, what each bot says it is doing, or else the start of its own latest reply. Groups keep their latest message. Sort Conversations has moved beside it, at the top of Settings.
- On iPad with a keyboard, the menu bar has the Mac's menus where Noodle on iPad can do the same: Settings… (⌘,), View › Sidebar (what the line under each name shows, and the order), View › Conversation (how attachments and long messages are laid out), New Space… and Edit Spaces… in Spaces, and Help › Noodle Help. The menus' groups are separated by lines.
- Settings › Conversation List › Layout › As Icons shows bots and groups as a grid of their pictures, as on the Mac, each with its name and the line Show chooses, or why its bots wait. On iPhone the grid fills the screen; on iPad and Mac it fills the sidebar. View › Sidebar › As List and As Icons choose it from the menu bar.
- Holding a bot or group, in the list or the icon view, shows its latest messages above its menu, to read without opening it.

### Fixed

- The Call button is disabled while a bot can't take a call: its Hub is out of reach, or the bot is stopped, starting, failed or paused. Messages can still be sent for it to pick up later. A widget's call button then only opens the chat.
- The line under a name shows what was last said, not Noodle's own notices such as "Back on Claude Code".
- A phone or iPad that has just joined a Hub shows the bots and groups you haven't read on your other devices as unread, instead of counting everything already there as read.

### What to Test

- In Settings, set Show to Status and check that a bot that has set a status shows it under its name, and one without shows its own latest reply rather than your message. Set it to Description and check that each bot and group shows what it is for.
- In Settings, set Layout to As Icons. Check that every bot and group shows as a picture with its name and line, in Pinned, Unread and the rest, that tapping one opens it and holding one shows its own menu, and that a long list scrolls with no gaps.
- Let a bot fall back to another harness and come back, then check the line under its name still shows its last reply, not "Back on …".
- Hold a bot or group in the list and in the icon view. Check its latest messages show above its own menu, and that in the icon view each picture shows its own.
- With the Hub out of reach, or a bot stopped, open its chat and check the call button is greyed out while the message field still works.
- Join a Hub on a device that hasn't joined it before, while another of your devices has unread conversations. Check the same ones show as unread.
- On iPad, open the menu bar (swipe down from the top, or hold ⌘ with a keyboard). Check View › Sidebar and View › Conversation change the list and the chat as Settings does, ⌘, opens Settings, Help › Noodle Help opens the Noodle page, and the … menu beside the list has lines between New Bot and New Group, Play, and Hubs and Settings.

## [0.51.0] - 2026-10-28

### Changed

- Bots' pictures show their status as on the Mac, with less noise. A ready bot has no dot; a working one is circled by a turning arc; a stopped one, or one on a Hub that isn't connected, is greyed out. A bot waiting for Kick keeps its red dot. Groups show their status too: circled while a member works.
- A group of two shows its members' pictures diagonally across its circle, larger than before, and the borders between members' pictures are thinner on small pictures.

### What to Test

- Send a bot a message and check that its picture is circled while it works and plain once it has replied. With the Hub out of reach, check that bots' pictures are greyed out.
- Send a message in a group and check that the group's picture is circled while a member works. Check that a group of two shows both pictures diagonally and large.

## [0.50.0] - 2026-10-28

### Changed

- Noodle opens and returns to your chats without stutter. When you come back to the app, the open chat updates first and the others update together in the background. A chat no longer redraws for messages in other chats, so scrolling stays smooth while Noodle catches up.
- Noodle keeps each chat's latest 200 messages on your phone between launches. Earlier messages load as you scroll back, as before.

### What to Test

- With a long chat open, switch to another app for a minute and come back. Check that you can scroll the chat smoothly right away, and that replies sent while you were away show up, in the open chat first.
- Quit Noodle and open it again. Check that the list and the open chat show at once and then update. In a long chat, scroll back and check that earlier messages still load.
- While a bot replies in another chat, scroll the open one. Check that it stays smooth and that the list shows the reply.
- Turn on Airplane Mode, then turn it off in Control Center and come back to Noodle. Check that it reconnects right away.

## [0.49.0] - 2026-10-27

### Added

- Tap a photo or file waiting above the message field to look at it before you send it, and swipe to the others waiting with it.

### Changed

- The Shared button in a conversation now uses the same stacked-squares icon as on the Mac, instead of three dots that looked like the More button.
- Deleting a space in Edit Spaces… asks first, so a stray swipe or tap no longer deletes it. Only the space is deleted; its bots and groups stay in All.

### Fixed

- A conversation no longer goes blank when the keyboard opens. It could scroll past the latest message, leaving empty space above the message field until you scrolled back by hand.
- After you pull a list down to refresh, the Noodle wordmark goes once the list is back in place, instead of staying at the top when the refresh shows that a Hub can't be reached.

### What to Test

- In a long conversation, tap the message field: check the latest messages stay just above the keyboard, with no empty space. Close the keyboard and open it again a few times, also right after opening the conversation: check the same. Send a message with the keyboard open: check it shows above the keyboard.
- In the list, pull down slowly: check the wordmark is written as you pull. Pull down far and let go: check the word goes up with the list and never sits over the first bot or the pinned bots, during the refresh or after it. With a Hub that can't be reached, pull to refresh: check the word goes once the list is back. Do the same in Hubs. On iPad, check the same in the list on the left.
- In a chat, add a photo and a file without sending them. Tap the photo: check it opens in a preview, and you can swipe to the file. Close the preview: check both still wait. Tap the x on one: check it is taken out, and the other still opens when tapped.
- Make a space and add a bot to it. Open the space menu, choose Edit Spaces… and delete the space with its red button, then by swiping its row: check each time it asks "Delete “Name”?" and Cancel keeps it. Choose Delete: check the space is gone and the bot is still in All. On iPad with a keyboard, press Esc at the question: check the space is kept.
- Open a conversation where a computer, browser tab or noodlet was shared: check the Shared button at the top shows stacked squares, as on the Mac, and opens the shared list. Check the More buttons still show three dots.

## [0.48.0] - 2026-10-26

### Added

- Keyboard shortcuts on iPad, as on the Mac. Hold ⌘ to see them: ⌘N for a new bot, ⇧⌘N for a new group, ⌘F to search, ⌥⌘↓ and ⌥⌘↑ for the next and previous chat, Esc to close the chat, and ⌘1 to ⌘9 for your spaces. Return sends your message and Shift-Return starts a new line. Esc closes sheets, as Cancel or Done does.
- With a mouse or trackpad on iPad, right-click a message for its reactions and actions, as touching and holding it does. Right-click a bot or group in the list for its menu. Rows, pinned bots and the message field's buttons light up under the pointer.

### Changed

- On iPad, … beside the list opens a menu, as on the Mac, instead of a sheet. Settings, Hubs, a bot's or group's editor and other forms open in a sheet sized for a form instead of one as large as a page. Short sheets, such as a bot's profile in a group and Pair's, are only as tall as their buttons. The Pair button and the welcome after pairing keep an iPhone's width in the middle of the screen. Open on iPad in a noodlet's menu shows an iPad.

### Fixed

- In Play on a 13-inch iPad on its side, the menu over a game is laid out for the iPad, not for a TV.
- Resizing Noodle on iPad in Split View or Stage Manager, between the list beside the chat and the list alone, no longer closes Settings, a bot's editor or another sheet opened from the list, or drops the files waiting to be sent in the chat. Files waiting to be sent also stay when you leave a chat and come back to it, as its draft does.

### What to Test

- On iPad with a keyboard: hold ⌘ and check the shortcuts show. Press ⌥⌘↓ and ⌥⌘↑: check the chats open one after another, in the list's order. Press Esc: check the chat closes. Press ⌘F: check the search field takes your typing. Press ⌘N and ⇧⌘N: check New Bot and New Group open, and Esc closes them. With two Hubs, press ⌘2: check the first Hub's space shows. In a chat, type and press Return: check it sends; press Shift-Return: check it starts a new line. With the on-screen keyboard, check return still starts a new line.
- On iPad with a mouse or trackpad: move the pointer over the list's rows, the pinned bots and the buttons beside the message field: check each lights up. Right-click a message: check its reactions and actions show, as after touching and holding it. Right-click a row and a pinned bot: check their menus show. Touch and hold a message with a finger: check it still works.
- On iPad, upright and on its side: tap … beside the list: check a menu opens, and each item opens what it names. Open Settings, Hubs, New Bot and a bot's Edit: check each is a form-sized sheet, not a page-sized one. In a group, tap a bot's picture: check its profile sheet is only as tall as its buttons. Leave all Hubs: check the Pair button is about as wide as on an iPhone, in the middle; tap it: check its sheet is short. In Play, open the menu over a game on a 13-inch iPad on its side: check the cards look as on a smaller iPad. On an iPhone, check … still opens the sheet and these screens look as before.
- On iPad, open a chat, add a photo without sending it, and open Settings. In Split View or Stage Manager, make the window narrow, then wide again, from a third of the screen to all of it: check Settings stays open, the chat stays open beside or over the list, and the photo still waits above the message field. On an iPhone, add a photo to a chat, go back to the list and open the chat again: check the photo still waits.

## [0.47.0] - 2026-10-26

### Added

- On iPad and the unfolded iPhone Duo, your bots and groups are in a column on the left, with the pinned ones on top, and the chat you open shows beside them, as on the Mac. On the iPhone Duo the fold runs between the two, with nothing on it. A tapped notification, widget or link opens its chat there too. Folding or unfolding the iPhone Duo keeps the chat you had open.
- On the iPhone Duo's cover screen, your pinned bots and groups are in the bar on the right, under the time, instead of above the list. Tap one to open its chat, or touch and hold it for its menu. A dot marks one with unread replies, and pins that don't fit are in the bar's … menu.

### Changed

- In a wide chat, as on iPad, messages stay a readable width instead of stretching across the screen.

### Fixed

- On the iPhone Duo's cover screen, the Noodle wordmark on the pairing screen is centred above the Pair button, and short sheets, such as Pair's and the one … opens, are centred under their grabber instead of off to the left of the bar with the time.

### What to Test

- On iPad or an unfolded iPhone Duo: check the bots are in a column on the left, the pinned ones on top, and No Conversation Selected on the right. Tap a bot: check its chat opens on the right and its row is marked. Tap a notification, or a bot in a widget: check its chat opens on the right. In a group, tap a bot's picture and choose Message: check its chat opens on the right. On the iPhone Duo, check the fold runs between the list and the chat, with no text or button on it. With a chat open, fold it: check the chat stays open on the cover screen; unfold it: check it shows on the right. On an iPhone, upright and on its side, check the list and chats work as before.
- In a chat on iPad, send a long message: check it wraps at a readable width rather than across the whole chat.
- On an iPhone Duo, folded, pin three bots: check they show in the bar on the right, under the time, and not above the list, with a dot on one with unread replies. Tap one: check its chat opens. Touch and hold one: check its menu shows, with Unpin. Pin ten: check the ones that don't fit are in the bar's … menu. Unfold it, or use another iPhone: check the pins are above the list as before.
- On an iPhone Duo, folded and not paired: check the wordmark is centred above Pair. Tap Pair: check its buttons are centred in the sheet. Once paired, tap …: check its buttons are centred too. On another iPhone, check the pairing screen and these sheets look as before.

## [0.46.1] - 2026-10-26

### Fixed

- The down arrow in a conversation no longer stays over the latest message after you scroll back down to it, and it waits until you are well above the latest message, not a few lines short of it. Scrolled back down to the latest message by hand, a conversation follows new replies again. Before, it left out the room under the bar and the message field, so it thought you hadn't reached the end yet.

### What to Test

- In a long conversation, scroll up a little, less than half the screen: check no down arrow shows. Scroll up further: check it shows. Scroll back down to the latest message by hand: check the arrow hides, and a new reply scrolls into view. Do the same with the keyboard open.

## [0.46.0] - 2026-10-25

### Added

- A conversation scrolled up to older messages shows a down arrow above the message field. Tap it to go back to the latest message, and new ones follow again. It hides once the latest message shows.

### What to Test

- In a long conversation, scroll up: check a down arrow shows at the bottom right, above the message field. Tap it: check the conversation goes to the latest message, the arrow hides, and a new reply follows. Open the keyboard while scrolled up: check the arrow sits above the message field, not under the keyboard. Scroll up while a reply arrives: check the conversation stays where you are reading.

## [0.45.0] - 2026-10-24

### Added

- Send to Agent in Shortcuts sends a message, files or both to a bot or group, straight to its Hub as the share sheet does, and can open the chat after sending. The message can be left out when files are attached.
- Siri knows Noodle's Shortcuts actions, with the same phrases as on the Mac, such as "Call Scout with Noodle", "Open chat with House in Noodle" or "Send to Scout with Noodle".

### Changed

- Shortcuts' Open Chat with Agent is now Open Chat, as on the Mac, and opens a group's chat too.
- In a Hub's Users, admins have an Admin tag in the accent colour beside their name, and suspended people a Suspended tag in orange, instead of grey text after their plan.

### What to Test

- In Shortcuts, add Send to Agent, choose a group, leave Message empty and add a file: check it arrives in the group as "Sent 1 attachment" with the file. Run it to a bot with a message and Open Chat on: check the message arrives and the bot's chat opens. Run it with neither a message nor files: check it asks what to send.
- Add Open Chat and choose a group: check the group's chat opens. Run a Shortcut made with Open Chat with Agent before updating: check it still opens its bot's chat, or asks for the bot if it lost it.
- Ask Siri "Call <bot> with Noodle", "Open chat with <group> in Noodle" and "Send to <bot> with Noodle": check each works. Check Call Agent and the Agent control on the Action Button still call the bot.
- Open a Hub where you are an admin and choose Users: check admins show an Admin tag in the accent colour and suspended people a Suspended tag in orange beside their name, and the line below shows only the plan.

## [0.44.0] - 2026-10-23

### Added

- Choose how a group notifies you: touch and hold it and choose Notifications, then Default, All Messages, Mentions Only or Muted. In Mentions Only, a reply notifies you and counts on the app icon only when it names you, by your full name or your first name alone as the Hub lists you; other replies still show unread. A muted group sends no notifications, not even for your name, stays out of Unread and isn't counted on the app icon; its row shows a grey dot when there are new replies. Settings has In Groups, Notify Me For, for the groups on Default. The choices apply to all your devices. One-to-one chats always notify. A Hub that can only mute groups shows Mute and Unmute, and older Hubs show neither.

### Changed

- A bot's Harness opens a list of the harnesses under the Hub that lends them, with a profile's name under its harness, as on the Mac, instead of a menu of bare names. A bot already made lists only its own Hub's harnesses; a new bot lists every Hub's, and choosing one makes it on that Hub.

### Fixed

- A call answered in the car stays on the car's speakers. If the call was on the iPhone speaker, connecting CarPlay, Bluetooth in the car, AirPods or other headphones now moves it there, and it no longer jumps back to the phone speaker.
- Mark Up on a PDF or a document such as a Word file shows its page to mark instead of a black screen. A PDF opened on its own shows in a viewer that marks the page you scrolled to; other documents mark their first page.

### What to Test

- Open a bot's info and tap Harness: check the harnesses are listed under the bot's Hub name, each profile's name shows under its harness, the current one has a checkmark, and only that Hub's harnesses are offered. Choose another: check the row shows it.
- With two Hubs joined, tap New Bot, then Harness: check each Hub's harnesses are under its name. Choose one on the other Hub: check the Hub row follows, and the bot is made there.
- Open a PDF a bot sent, scroll to its second page and tap Mark Up: check that page shows, not a black screen, and a box dragged on it goes with the comment. Do the same with a .docx: check its first page shows. Check Mark Up on a picture still works as before.
- In Settings, choose In Groups, Notify Me For: Only When My Name Is Mentioned. Have a bot reply in a group without your name while Noodle is closed: check no notification arrives and the icon doesn't count it, but the group shows unread. Have it reply with your first name: check it notifies. Check your Mac shows the group in Mentions Only too.
- Touch and hold a group and choose Notifications, then Muted. Have a bot reply there while Noodle is closed: check no notification arrives, the app icon doesn't count it, and the group isn't under Unread but shows a grey dot. Check the group shows as muted on your Mac too. Choose Unmute: check the next reply notifies again.
- In a car with CarPlay or Bluetooth, have a bot call you and answer on the car's screen: check you hear the bot through the car's speakers, never the phone speaker. Call a bot with Speaker on, then connect CarPlay or AirPods during the call: check the call moves there and stays there.

## [0.43.1] - 2026-10-23

### Fixed

- Taps in the padding around the message text now focus the input, so the visible message field responds above and below its text too.
- Conversations keep their horizontal alignment and their last message in place as the message field grows or the keyboard moves.
- Scrolling up to read older messages stops following the newest ones immediately, instead of sometimes jumping back down.

### What to Test

- Open an empty, short or long conversation and tap near the top, bottom and left of the message field before scrolling: check the keyboard opens. Type more than six lines and check the draft scrolls inside the field.
- Scroll up through older messages, including while earlier messages load or a reply arrives: check the conversation stays where you are reading. Scroll back to the bottom and check new replies follow again. Check a long reply opens at its beginning and a message you send stays visible at the end.
- Open a long conversation and type a multiline draft, then show and hide the keyboard: check the messages stay aligned and the conversation does not scroll beyond its last message.

## [0.43.0] - 2026-10-22

### Added

- The pasta effect: penne, farfalle, fusilli and macaroni fall over a chat when a bot sends it for a moment nobody is quite sure about. Needs the Hub updated.
- Put your Hubs' spaces in order: open the space menu, choose Edit Spaces… and drag them. All stays first. The order is kept on this phone.
- Call a bot or open its chat from Shortcuts, Control Center or the Action Button: Shortcuts has Call Agent and Open Chat with Agent, which ask for the bot when it runs unless you choose one, and the Agent control calls the bot or opens its chat, as you choose when adding it. Calling a bot that can't take calls opens its chat instead.
- A bot on your Hub that waits for Kick says why at the top of its conversation and in its row, such as "Paused: recovery interrupted", with a Kick button for your own bots. Needs the Hub updated.
- A bot on your Hub that a limit holds says so the same way, with when it continues, such as "Paused: plan limit, resumes at 14:20" once you used the tokens your plan allows. Needs the Hub updated.

### Fixed

- A bot's call that iOS keeps off the call screen, as while a Focus silences Noodle, also shows as a missed call notification instead of nothing. Noodle logs each step of a call rung through Noodle Push, under Calls in Console, to tell why a call didn't ring.
- On iOS 27.1 the message field sits as low as the search in the bots list again, and with the keyboard up a conversation ends right above the field instead of leaving a gap under its last message.

### What to Test

- On iOS 27.1, open a conversation: check the message field's bottom lines up with the bots list's search. Tap the field: check the last message sits right above it with no gap, and still does after sending a message.
- Lock the phone, then right away have a bot call you: it rings on the call screen. With a Focus that doesn't allow Noodle, the missed call also shows as a notification.
- Ask a bot to send the pasta effect, then open its conversation: check pasta shapes in warm colours fall from the top and sway, once. With Reduce Motion on, check a still 🍝 shows instead.
- With two or more Hubs joined, open the space menu and choose Edit Spaces…: drag a Hub above another, then check the menu lists them in that order after All, and still does after closing and reopening Noodle. Check the Hubs can't be renamed or deleted there.
- In Settings › Action Button choose Controls, then Noodle's Agent: pick a bot that takes calls and Call. Press the Action Button, also with Noodle closed: check its chat opens and the call starts. Change the control to a bot that can't take calls: check it shows a chat bubble and pressing it opens the chat only.
- Add the Agent control to Control Center with Open Chat: check pressing it opens that bot's chat.
- In Shortcuts, add Call Agent with no bot chosen and run it: check it asks which bot, then calls it. Add Open Chat with Agent with a bot chosen: check it opens that chat without asking. Leave the bot's Hub, run it again: check it says the agent is no longer available.
- Make a bot on the Hub wait for Kick, for example by interrupting a Grok Build recovery: check its row and the top of its conversation say why, and Kick there starts it again.
- On a Hub plan with a small token limit, use it up: check the bot's row and the top of its conversation say "Paused: plan limit" with the time it resumes, and nothing is written in the conversation.

## [0.42.1] - 2026-10-22

### Changed

- Calls from your bots show in the Phone app's Recents, so you can see a bot tried to reach you even when a Focus silenced the call.

### Fixed

- The speaker button on the lock screen's call screen keeps a bot's call on the loudspeaker instead of switching back to the earpiece a moment later.

### What to Test

- Turn on a Focus that doesn't allow Noodle, lock the phone and have a bot call you: check the call shows as missed in the Phone app's Recents with the bot's name.
- Have a bot call you while the phone is locked, answer and tap Speaker on the call screen: the voice stays on the loudspeaker, the bot doesn't hear itself, and Speaker in the app matches. Tap it again to go back to the earpiece.

## [0.42.0] - 2026-10-21

### Added

- Calls from your bots ring on the phone's call screen even while Noodle is closed or the phone is away from home, with the bot's name. Answer connects the call once the phone reaches your Hub; if it can't, a notification says you missed the call. Needs the Hub, or Noodle on the Mac, updated.

### Changed

- The small Bot widget's Call button is a round green button with a phone in the bottom-right corner, which leaves the bot's picture and name more room. Turn off Show Call Button in the widget's settings to leave it out.

### Fixed

- The first message you send after opening a conversation stays in view above the message field, instead of the conversation scrolling past its end to a blank screen until you scroll it back.
- The app icon shows how many conversations have replies you haven't read, on all your Hubs, as Messages does. It counts replies that come while Noodle is closed, and goes down as you read them here or, while Noodle is still in the app switcher, on another device.

### What to Test

- Close Noodle from the app switcher, then ask a Codex bot on your Hub to call you: check the phone rings on the call screen with the bot's name, and that Answer connects the call in its conversation.
- Lock the phone with Noodle closed and have a bot call: check it rings on the lock screen and Answer works without unlocking first.
- With Noodle closed, decline a call: check it stops ringing on your Mac too, and the bot's conversation shows a Declined call card.
- With Noodle closed, answer a call on your Mac instead: check the phone stops ringing.
- Turn Wi-Fi off and use mobile data, with Noodle closed: check a bot's call still rings and connects when answered.
- Quit Noodle Hub, or turn off the Mac, and have the phone ring from a call placed just before: check Answer gives up after a few seconds with a "Missed call" notification naming the bot and the Hub.
- With This Mac as a Hub on and Noodle closed on the phone, have a bot on the Mac call: check the phone rings too.
- Add the small Bot widget for a bot that takes voice calls: check a green round phone button sits in the bottom-right corner, clear of the picture and the name, and the picture is larger than before. Tap it, also with Noodle closed: check the chat opens and the call starts. Tap anywhere else: check only the chat opens.
- Choose a bot with a long name: check the name shows on up to two lines next to the button instead of being cut short.
- Touch and hold the widget, choose Edit Widget and turn off Show Call Button: check the button goes and the name is centred under the picture. Turn it back on and check the button returns. Check widgets added before this update still show the button.
- Choose a bot that cannot take calls: check there is no button whatever the setting. Use a tinted Home Screen and dark mode: check the button can still be read. With VoiceOver, check the bot's name and "Call" with its name are read separately.
- Open a long conversation for the first time since launching Noodle, tap the message field and send a message: check your message shows just above the field, with no blank screen. Send another, and check it does the same.
- Repeat in a conversation you have already opened, with the keyboard already up, and in a short conversation.
- Leave Noodle and have two bots reply: check the app icon shows 2, and that a third reply from one of them keeps it at 2. Open one conversation and check the icon shows 1 once you are back on the Home Screen.
- With Noodle in the background, not closed from the app switcher, read a conversation in Noodle on your Mac: check the icon's number goes down and its notification leaves Notification Center.

## [0.41.0] - 2026-10-20

### Added

- Hub admins can suspend and restore regular users from their user details, keeping their plan, data and paired devices.
- Your bots on a Noodle Hub can call you when something needs you now. While Noodle is open, the call rings on the phone's call screen with the bot's name; Answer starts the call and Decline turns it down. A call you decline or miss shows as a card in the bot's conversation, with why it called. Needs the Hub updated.
- Sign in to a page in a browser you watch live with your iPhone's own fields: tap the key, pick your login from Passwords or type it, and tap Fill. Codes from Messages are offered too. Turn on Submit to send the form as well. Needs a Hub and Noodle Browser that offer it.

### What to Test

- As a Hub admin, open Users, select a regular user and turn on Suspended. Their bots stop and devices lose access. Turn it off to restore access without pairing again. Admin users cannot be suspended from a device.
- With Noodle open, ask a Codex bot on your Hub to call you (it runs messenger --call --reason "…"): check the call screen rings with the bot's name, and that Answer connects the call in its conversation, with the bot saying why it called.
- Let a call ring out, and decline another: check each leaves a Missed call or Declined call card from the bot with its reason, and that the bot writes to you instead.
- With Noodle on a Mac paired with the same Hub, answer or decline on one device: check the other stops ringing.
- Open a browser a bot shared at a sign-in page and tap the key: check the sheet names the site with a lock, and offers only the fields the page has. Pick a login from Passwords, tap Fill, and check the page shows the username and dots for the password, and is not submitted. Repeat with Submit on and check it signs in.
- On a page asking for a code sent by text message, tap the key: check the code from Messages is offered above the keyboard and fills the page's boxes.
- Fill a password without signing in and close the live view: open it again and check the password field is empty.
- On a page with no sign-in fields, tap the key: check it says none were found. With a Hub or Noodle Browser that cannot sign in, check the key does not show or the message names what to update.

## [0.40.0] - 2026-10-20

### Added

- Tap …, choose Hubs and tap your Hub: it lists all your computers and browsers on it, whichever bots have them. Tap one to change its name and description, or swipe to delete it.
- Touch and hold a file in a conversation and choose Forward… to send it to another bot or group, with an optional comment. It arrives there as your message, as if you had attached the file yourself.
- Touch and hold a text file in a conversation to Copy its text or Copy File, which pastes into other apps as the file.
- Paste a copied file into the message field to attach it, instead of its text. Long pasted text, over 12 lines or 1,200 characters, is attached as a text file, as on the Mac.
- The small Bot widget has a Call button for a bot that takes voice calls. Tap it to open the chat and call the bot straight away; tap anywhere else to open the chat as before.

### Changed

- Tap a voice message to read its transcript, with its waveform to play it and tap or drag through it. The sentence being played is marked, roughly, since it follows the time rather than the words, and tapping a sentence plays from there. Copy copies the transcript. The play button still plays and pauses, and Show Transcript, when you touch and hold the message, opens the same.

### Fixed

- Deleting a tool, computer or browser in a bot's settings asks first. It says which of your bots lose it, and that a computer moves to the Trash on the Hub or that a browser's sign-ins and history are erased for good.

### What to Test

- Tap a voice message away from its play button: check its transcript opens with the waveform and the time. Tap Copy and paste somewhere: check the whole transcript arrives.
- Play it there, and tap and drag along the waveform: check playback moves, the marked sentence follows roughly, and the message in the conversation shows the same progress once you close the transcript.
- Tap a sentence: check playback jumps to about where it is said. In a long transcript, check the marked sentence stays in view as it plays.
- Touch and hold a voice message and choose Show Transcript: check the same transcript opens.
- Open a voice message sent without a transcript: check it says "No transcript was made for this voice message." and plays.
- Open a voice message the moment it arrives, before its audio has downloaded: check the transcript shows straight away and play works once the audio is in.
- With VoiceOver, check play is its own button and the message offers Show Transcript as an action.
- In a bot's settings, open Tools, Computers and Browsers and swipe one to delete it: check a confirmation asks first and names the bots that use it. Check it says a computer moves to the Trash on the Hub and a browser's sign-ins and history are erased. Tap outside it and check nothing is deleted; delete one and check it goes.
- Tap …, choose Hubs and tap your Hub: check Computers and Browsers show with how many you have. Open each and check every one is listed with its description, or a computer's state.
- Tap one, change its name and description and tap Save: check the list shows them, and so do the bot's Computers or Browsers and Noodle on the Mac. Clear a description, save, and check it is gone.
- Swipe one to delete it: check the confirmation names the bots that use it, and that after Delete it is gone from the list and from those bots.
- With a Hub that cannot list computers or browsers, check those rows do not show.
- Touch and hold a picture or another file in a conversation and choose Forward…: check the sheet names the file and lists your bots and groups, without the conversation you are in, and that search finds them by name.
- Pick a bot or group, write a comment and tap Send: check the sheet closes, and that conversation shows one message from you with the file and your comment as its text. Check the bot answers about the file.
- Forward without a comment: check the message says "Sent 1 attachment".
- Forward a file you have not opened yet, and a large one: check Send waits while it downloads, then it goes.
- With two Hubs joined, check bots from both are listed, each with its Hub's name, and that forwarding to the other Hub works.
- Touch and hold a voice message, a comment card, a link, or a shared computer or noodlet: check Forward… does not show.
- Turn on Airplane Mode and forward a file you have opened: check the message shows Not delivered in the other conversation, and goes when you try again with the connection back.
- Touch and hold a text file in a conversation: check Copy and Copy File show, and a picture or PDF shows neither. Choose Copy and paste into Notes: check its text arrives.
- Choose Copy File and paste into the message field: check the file waits above the field with the same name, and sends. Paste it into Files or Mail: check it arrives as a file.
- Copy a file in the Files app and paste it into the message field: check it is attached, not its text.
- Paste text of more than 12 lines into the message field: check it is attached as Pasted Text.txt and the field stays as it was. Paste a short text: check it goes into the field as before. Copy a picture and paste it: check it is attached as before.
- With a bot that takes voice calls, open Noodle, then add the small Bot widget for it, or edit one you have to show it: check a green Call button shows under its name. Tap Call, also with Noodle closed: check its chat opens and the call starts, asking for the microphone the first time, as the chat's Call button does, and you hear the bot.
- Tap the widget away from Call: check only the chat opens. Choose a bot that cannot take calls: check there is no Call button. Use a tinted Home Screen: check Call can still be read. With VoiceOver, check the bot and "Call" with its name are read separately.

## [0.39.0] - 2026-10-18

### Added

- Comment on files and messages, as on the Mac. In a file's preview, tap Mark Up and drag a box around what you mean, then write or dictate your comment. Pick lines of a patch by their numbers, or select text in a text file, and choose Comment…. Long-press a message or a file in the conversation and choose Comment… to comment on all of it. Comments wait above the message field until you send your next message, which takes them to the bot. Tap one to change it. Needs a Hub that keeps comments.
- Comments from your Mac or another device show as cards with the part marked or the text quoted.

### What to Test

- Open a picture, a PDF and a text file from a conversation and tap Mark Up: check "Drag to mark an area" shows and goes once you drag, and lifting your finger opens the comment sheet with the area you marked outlined in orange. Write a comment and tap Save.
- In the comment sheet, tap the microphone and speak: check your words are added to the comment once you stop.
- Open a patch, open a file and tap a line's number, then drag down the numbers: check the lines are highlighted and Comment… opens the sheet with those lines.
- Select some words in a text file and choose Comment… from the menu over them.
- Long-press a message and choose Comment…; long-press a file and choose Comment….
- Check each comment waits above the message field with its picture and first words. Tap one to change its comment, and remove one with its ×. Leave the conversation and come back, also after quitting the app: check they are still there.
- Send a message: check the comments go with it, show as Annotation cards, and the bot answers about what you marked or quoted.
- With a Hub that has not been updated, check Mark Up and Comment… do not show and files open as before.

## [0.38.0] - 2026-10-18

### Added

- A .patch or .diff file in a conversation shows its commits and the files that changed most on its card, as on the Mac. Tap it to read the patch: a walkthrough of its commits, its files by folder with a filter, and each file's changes with line numbers. Tick files off as Viewed; this phone remembers them.

### What to Test

- Ask a bot to send a patch of a change made with `git format-patch`: check its card shows the commits, the files that changed most with the lines added and removed, and the totals.
- Tap the card: check the walkthrough lists each commit with its message and the files are grouped by folder. Tap a file: check its changes show with line numbers, added lines in green and removed ones in red, and long lines wrap.
- Tick some files as Viewed with their circle or by swiping, then close the review and open it again, also after quitting the app: check they are still ticked, and the eye button hides them.
- Type part of a file's name in the search field: check only matching files show.
- Send a .diff file that is not a patch, such as plain text: check it opens in Quick Look as before.

## [0.37.0] - 2026-10-17

### Added

- Home Screen widgets for your bots. Bot shows the one you choose, with its picture and name, also on the Lock Screen. Bots shows the bots of All or of a space you choose. Tap a bot to open your chat with it.

### Changed

- Tapping a notification opens its conversation even when another space is shown.

### Fixed

- A bot's profile in a group shows Reply, Message, Call and Edit as matching rounded buttons on one line, instead of uneven ovals with Message split over two lines, and they sit right under a short description.
- Groups suggested in the share sheet show their bots whole inside the round picture, instead of with their edges cut off.
- Noodle reconnects to your Hub within seconds after you switch between Wi-Fi and mobile data, turn off airplane mode or come back to the app, instead of sometimes staying unable to connect for a long time. A slow or patchy connection no longer keeps new messages from arriving while older conversations load, and a connection that goes silent is noticed and replaced.
- When your Hub can't be reached, a bar above your chats says so and keeps retrying, with Try Again to retry at once. Not Connected has Try Again too.

### What to Test

- With the app open, turn on airplane mode for a few seconds, then turn it off: a bar says Noodle can't reach your Hub, then goes away within a few seconds, and new messages arrive.
- Switch between Wi-Fi and mobile data with the app open, and again with it in the background before coming back: new messages arrive within seconds without closing the app.
- With the Mac your Hub runs on asleep or its Hub quit, open the app: the bar shows above your chats. Tap Try Again, then wake the Mac or open the Hub: the bar goes away and new messages arrive.
- On a weak connection, such as one bar of mobile data, open the app: new messages still arrive while the conversations catch up.

- In a group, tap a bot's picture with no description, then one with a long description: the four buttons are the same size with one-line titles, sit just below a short description, and a long description scrolls.
- Send a message in a group with two bots and one with three, then share a photo from Photos: both groups' suggestions show every bot whole inside the circle. Suggestions update after the next message in each group.
- Open Noodle, then add the small Bot widget to the Home Screen; check it shows your first bot. Touch and hold it, choose Edit Widget, pick another bot, and check its picture and name show. Tap it; check Noodle opens that bot's chat.
- Add Bot to the Lock Screen and choose a bot; check its picture shows and tapping it opens its chat.
- Add the medium and large Bots widgets; check they show the bots of All, pinned ones first, and the large one says All above them. Edit one, choose a Hub and then a space you made, and check only that space's bots show. Tap a few bots; check each opens its own chat, also when a different space is shown in Noodle.
- In Noodle, rename a bot, change its picture, pin one in a space and archive another; check the widgets follow within a few seconds. Delete the space a widget shows; check it asks you to choose another.

## [0.36.0] - 2026-10-17

### Added

- In a group, tapping a bot's picture beside its messages shows its profile from the bottom of the screen, with Reply, Message, Call and Edit, as on the Mac.
- Settings › Sort Conversations, as on the Mac: newest first, unread first, or unread bots and groups in an Unread section at the top. Pinned ones stay in their circles.

### Changed

- The bot editor has a Description field and a Backstory section, as on the Mac. Its picture opens the picture editor without a row arrow.
- Image Generation is now listed under the bot's Tools, as on the Mac, and switches on or off as soon as you tap it.
- Group Info lists the group's bots first, so you can remove one without hunting, then the bots in the space you are viewing, then the rest. Rows stay put as you tick and untick them.

### Fixed

- The screen stays on while you dictate a voice message and it is transcribed, instead of dimming and locking.
- Sending a message or voice message keeps the conversation at its end, instead of leaving a gap below it or scrolling past it to a blank screen.

### What to Test

- Set Auto-Lock to 30 seconds, start a voice message and keep talking for over a minute; check the screen never dims, and dims again as usual after you send or cancel it.
- In a group, tap a bot's picture beside its messages; check its profile slides up with its picture, name, status and description.
- Tap Message; check the bot's own conversation opens, and Back returns to the group.
- Tap Reply; check the message field starts with the bot's name.
- With a bot that can take calls, tap Call; check the call starts and its conversation opens with the call bar.
- Tap Edit on your own bot; check its editor opens. For a bot someone shared with you, check there is no Edit.
- In Settings, set Sort Conversations to Unread First; have a bot that is lower in the list reply, and check it moves to the top, then stays in its usual place once you have read it.
- Set it to Unread Section; check unread bots and groups appear under Unread, the rest under Others, and that the Unread section goes away once everything is read.
- Edit a bot; check its picture has no arrow beside it and tapping it opens the picture editor. Fill in Description and Backstory, tap Save, then reopen the bot and check both were kept.
- Open the bot's Tools and tap Image Generation; check a tick appears straight away and the Hub's image model shows beneath it. Go back, tap Save and reopen the Tools; check the tick is still there. Tap it again to switch it off.
- Choose a space you made, open a group's Group Info and check its members are at the top, then the space's other bots, then the rest, each by name.
- Tick and untick a few bots; check no row moves until you close and reopen Group Info.
- In All, check members come first and every other bot follows by name.
- In a long conversation, send a few messages and voice messages, with the keyboard up and down; check each time the conversation ends just above the message field, with no gap and no blank screen.

## [0.35.0] - 2026-10-16

### Added

- Noodle is in the share sheet: send a screenshot, photo, video, file, link or text from any app to a bot or group, with a message.
- The bots and groups you talk to most recently show at the top of the share sheet, as in Messages, ready to send to in one tap.

### Changed

- Inline code in messages is a little smaller and dimmer, so it sits more quietly in the text.
- Reply notifications show the bot's picture, and a group's notification names the group and the bot that replied.

### What to Test

- Ask a bot for a reply with inline code, such as a file path; check the code is slightly smaller and dimmer than the words around it in light and dark mode, and still readable in your own blue bubbles.
- Take a screenshot, tap its thumbnail, tap Share and choose Noodle; pick a bot, add a message and tap Send. Check the screenshot and message arrive in the conversation.
- Share several photos from Photos, a page from Safari and a PDF from Files to a bot and to a group; check each arrives with its name.
- After sending to a bot a few times, open the share sheet again; check the bot shows in the top row with its picture, and tapping it opens Noodle's share sheet with that bot already chosen.
- Get a reply while Noodle is closed; check the notification shows the bot's picture, and a group's reply shows the group's name and the bot.
- Leave a Hub; check its bots stop showing in the share sheet.

## [0.34.0] - 2026-10-16

### Added

- Settings > Long Messages can split long replies into a bubble per paragraph, or into short chunks that keep a lead-in with its list.

### What to Test

- Switch Long Messages between Together, Paragraphs and Chunks; check a long reply breaks up as described, reactions sit on its first bubble and Copy copies the whole message.

## [0.33.0] - 2026-10-15

### Changed

- The background picker offers 40 gradients in place of four, from pastels to neutrals, as a grid of round swatches. Gradients are no longer dimmed, so they show their true colours.
- The starter team made on your first Hub wear drawn faces that suit their names, in place of icons.
- Bot Picture shows a Picture or Symbol switch, with only that choice's options beneath it, in place of Use Symbol Instead. Switching to Symbol and back keeps the picture, and Create Image reads Edit Image when there is a picture to start from. Editing a picture no longer adds the bot's name and description to your prompt.

### What to Test

- In a bot's Bot Picture, switch between Picture and Symbol; check the preview follows, the picture comes back after switching to Symbol and back, and saving keeps the one showing.

## [0.32.0] - 2026-10-14

### Added

- A new bot starts with a name and a drawn face that suits it, and the button beside the name tries another name with another face, until you choose a picture. Bot Picture also has Choose Face to pick from all of them.

### Fixed

- Pictures and videos in conversations can be saved to Photos from the share menu, not only to Files.

### Changed

- Calls show on the iPhone's call screen, keep going when the phone is locked, and can be muted or ended from the Lock Screen and from headphones.
- A call's audio goes over your Hub connection, and the Hub connects to the bot's voice. This needs the Hub update released alongside.
- A new bot introduces itself as soon as it is ready, without waiting for you to write. The starter team introduces themselves in their group instead of answering a greeting sent in your name. This needs the Hub update released alongside.

### What to Test

- Call a bot, lock the phone and keep talking; check the call goes on, the Lock Screen shows it, and Mute and End there work.
- During a call, turn Speaker on and off a few times; check the bot hears you and you hear it each time, with no echo of the bot on the loudspeaker.
- Call a bot with AirPods connected; check you hear the bot in them and it hears you.
- Mute and unmute from the call bar and from the call screen; check both show the same state and the bot stops hearing you while muted.
- Touch and hold a picture in a conversation, choose Share, then Save Image; allow access when asked and check the picture is in Photos.
- Make a new bot; check it says hello in its conversation within a few moments, before you write anything.
- Pair with a Hub where you have no bots yet and tap Continue on the team; check each of the three introduces itself in the Team group and no message appears from you.
- Make a new bot; check it starts with a name and a face, and that tapping the arrows beside the name changes both, with a woman's face for a woman's name and a man's for a man's.
- In a bot's Bot Picture, tap Choose Face and pick one; check the bot shows it after saving and keeps it.

## [0.31.0] - 2026-10-13

### Added

- Organize in a bot's settings asks an idle bot on your Hub to tidy its own files, as on the Mac. The bot sends a short note on what changed.

### Changed

- Pictures in conversations show at once when scrolled back into view, and shared noodlet, browser and computer cards keep their last picture after the app restarts.
- Files downloaded from your Hub are no longer included in iPhone backups, and the least recently viewed are removed once they take more than 512 MB; they download again when opened. Files of messages not yet sent stay in backups.
- Pictures, videos and PDFs in conversations show from small previews your Hub makes; the whole file downloads only when you open, share or use it as a background. This needs the Hub update released alongside.
- A web page linked in several conversations is previewed once.
- When a noodlet you played before has a large update, the version you have starts at once and the new one downloads meanwhile, with its progress shown at the top. For a small update, Play Previous Version sits below the download progress instead of over it. This needs the Hub update released alongside.

### What to Test

- Open an idle bot's settings, tap Organize, and check the bot replies with a short note on what it tidied. While the bot is working, check Organize is dimmed.
- Scroll a conversation with many pictures up and back down; check pictures appear without a spinner the second time and scrolling stays smooth.
- Quit the app and open a conversation with a shared noodlet, browser tab or computer; check its card shows its picture straight away.
- In a conversation with a large photo, a video and a PDF from a bot, check each shows a picture quickly; tap each and check it opens in full, and share one from its menu.
- Open a large noodlet game you played before after the bot changed it; check the old version starts straight away, "Downloading new version" shows its progress at the top, and "New version ready for next time" follows. Do the same with a small noodlet, in portrait and sideways; check Play Previous Version shows below the progress and never over it.

## [0.30.2] - 2026-10-12

### Fixed

- Wrapped text in message tables no longer overlaps adjacent rows.
- Table header backgrounds no longer overlap the first row after reducing the text size.

### What to Test

- Open a table with long cells and check that each row has enough space for its text, including at larger text sizes.
- Increase and then reduce the text size with a table open; check that the grey header background shrinks with the headings.

## [0.30.1] - 2026-10-11

### Added

- While a changed noodlet downloads again, Play Previous Version plays the one already on the phone; the new one keeps downloading, says when it is ready, and opens next time.

### What to Test

- Open a large noodlet game, have its bot change it, open it again, tap Play Previous Version while it downloads, and check the old one plays. Keep playing until "New version ready for next time" shows, then close it, open it again and check the new one starts without downloading.

## [0.30.0] - 2026-10-11

### Added

- Image Generation in a bot's settings lets it make pictures with the Hub's image models, and shows the model it would use.

## [0.29.0] - 2026-10-10

### Added

- Settings > Downloaded Noodlets lists the noodlets kept on the phone with their sizes, to delete one or all of them and free up space. A deleted noodlet downloads again the next time it opens.

### Changed

- Noodlet games can put Shift, Control and Alt on controller buttons, and let a button press a key the stick also uses, such as gas on a trigger while the stick steers.
- A noodlet the Hub is preparing says "Packing files" while it loads.

### Fixed

- A noodlet downloading from the Hub keeps the phone awake, and if the connection drops, as when the phone is locked, it carries on from where it stopped instead of failing.
- Sound in noodlets that play it through an audio worklet, as many web games do, now plays instead of failing to start.

### What to Test

- Start a large noodlet game, lock the phone while it downloads, unlock it, and check the download finishes.
- Open a noodlet game with sound and check you hear it.
- Play a noodlet game with a controller and check every button and both sticks do what the game shows.
- Open a noodlet that runs on the Hub and check it says "Packing files" while the Hub prepares it.
- In Settings, open Downloaded Noodlets, check the sizes look right, delete a game by swiping, then open it again and check it downloads and plays.

## [0.28.0] - 2026-10-10

### Added

- Noodlets can be games exported for the web by engines such as Godot, Unity and Emscripten, including ones that run on several threads on iOS 27 and later.
- While a noodlet comes from your Hub, its screen says what is happening: Preparing on Hub, then how much has downloaded, Unpacking and Starting, and fades into the noodlet once it has drawn.

### Changed

- A noodlet can download up to 1 GiB from the web in one request, up from 16 MiB.

### What to Test

- Open a few noodlets you already have, including games, and check they look and play as before.
- In a noodlet that loads things from the web, check they still load.
- Open a large noodlet for the first time, or after it changed, and check the screen shows its download progress.

## [0.27.0] - 2026-10-09

### Changed

- Edit Spaces… in the title menu puts your spaces in any order by dragging, renames them and deletes them, replacing Rename Space… and Delete Space. The order follows you to your other devices.

### Fixed

- Changes made just as the app connects to a Noodle Hub, such as a conversation pinned on another device, are no longer missed.
- Games that read game controllers directly work on a TV: the controllers no longer stop when the game moves from the phone to the TV.

### What to Test

- With a game controller connected, open a game that supports controllers and show it on a TV: the controller plays the game there, sticks and all, and a second controller adds a second player. Press View: the menu opens and the game doesn't react. Bring the game back to the phone: the controllers keep working, one player per controller.

## [0.26.0] - 2026-10-08

### Changed

- Talking to a Noodle Hub is quicker: the app keeps one connection open and sends everything over it, instead of connecting again for every request. Live views keep a connection of their own.
- Games can read game controllers directly, as they do in Safari: analog sticks, every button, and several controllers for several players. Such a game no longer gets each press twice, as a key as well.
- Games run faster on the phone and on a TV: they draw at most what a games console does, 720p on an iPhone and 1080p on an iPad or a TV, scaled up to fill the screen.

### Fixed

- While a full-screen game loads, Done and the buttons beside it stay in the top corners instead of starting in the middle and jumping out.

### What to Test

- Open a heavy 3D game noodlet: it runs smoother than before and still fills the screen. Show it on a TV: it fills the TV and stays smooth. Text and buttons outside the game look as sharp as before.
- With a game controller connected, open a game that supports controllers, such as one made for several players: press a button: one player joins, not two. Connect a second controller: a second player can join. Show the game on a TV: the controllers keep working.
- A game played only with keys still plays with a controller as before.
- Open a full-screen game: while it loads, Done and the buttons are already in the top corners and stay there.
- With the latest Noodle Hub, open several conversations one after another: each opens quicker than before. Leave the app for a minute, come back and open another: it still opens. Restart the Hub, wait a moment, and open a conversation: it opens without hanging.

## [0.25.0] - 2026-10-08

### Added

- A noodlet, run on the phone or watched live from a Hub, says in its top right corner when it is still starting or too busy to respond.
- When your phone is joined to your Mac, you can share the Mac's bots with people on the Noodle Hubs the Mac joined. Edit the bot and tap Sharing, or Sharing on a Hub's name when the Mac joined several.
- Chat effects: confetti or fireworks a bot sends play when you open its conversation, within a day, on whichever of your devices shows it first.
- Play: tap … and choose Play to turn the phone into a games console. It shows every noodlet your bots shared, on all your Hubs, with games first. With a TV connected by Screen Mirroring or a cable, the console shows on the TV and the phone becomes its controller; a game controller steers it too.
- Joining your first Hub welcomes you with a team of three bots, as Noodle does on the Mac: a personal assistant, a developer and a researcher, with their own group. They use what your plan on the Hub lends, so there is nothing to set up, and Continue says hello to them in their group.

### What to Test

- Open a large game noodlet: "Starting…" shows in the top right corner until it first draws. If it then freezes while it loads, "Not responding" shows until it moves again. Watched live from a Hub, the same notices show.
- With your phone joined to your Mac (Settings → Hub → This Mac on the Mac), and the Mac joined to a Noodle Hub with other people on it, edit one of the Mac's bots on the phone: Sharing shows. Tap it, tap a person: the bot shows for them on that Hub, and in Edit Bot on the Mac.
- With the Mac joined to two Hubs, Edit Bot on the phone shows Sharing on each Hub's name, each with that Hub's people.
- Ask a bot on a Hub to celebrate with confetti while the app is closed, then open its conversation: the confetti plays once. Open the same conversation on your Mac or iPad afterwards: it does not play again. Ask for fireworks with the conversation already open: they play straight away.
- With Reduce Motion on (Settings → Accessibility → Motion), the effect shows as a still 🎉 or 🎆 instead.
- Bots kept on a Noodle Hub show Sharing as before.
- Tap … and choose Play: the Noodle wordmark writes on, then the noodlets your bots shared show as cards, newest first, including ones shared long ago. The cards are stacked, the chosen one in front and the rest turned away to each side. Tap a side card to bring it to the front, tap the front one to play. Swipe through the stack. Done closes it.
- Every game noodlet shows under Games, including ones never opened on this phone (needs the latest Noodle or Noodle Hub). Tap Games or Noodlets at the top to switch between them; up and down on a controller switch them too.
- With Screen Mirroring to a TV on, choose Play: the console shows on the TV and the phone shows a d-pad and an A button to move and play. Start a game: it plays on the TV with the phone as its controller. Close it from the controller's View button menu, or Done: you are back at the console, still on the TV.
- With a game controller connected, steer the console with the d-pad or left stick and play with A, on the phone or the TV. While a noodlet started from Play is open, the controller's View button shows the same stack over it, ending with Home: choose another to switch, Home to go back, View or B to carry on. Opened from a conversation, the View button shows its usual menu.
- The phone stays awake and sideways while the console is open, and turns freely again after Done.
- On a phone with no Hub, pair with a Hub where you have no bots: the wordmark rises, three bots come in one by one with their names and roles, then Continue opens their Team group with your hello, and they answer.
- Pair with a Hub where you already have bots, or pair a second Hub: there is no welcome and no new bots.
- On a Hub whose plan lends no harnesses, the welcome says so, and Not Now shows the list.
- Turn on Airplane Mode while the team is being made, then off again: Try Again finishes the same team without making any bot twice.

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
