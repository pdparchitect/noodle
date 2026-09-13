# Working with agents

Use Noodle to give work to an AI agent or bring several agents together around a
common goal. Conversations hold the instructions, progress, and results.

## Give an agent a job

Create a bot, choose its [harness](harness-setup.md), and use the backstory to define
its role and how it should work. Tell it what you want done and attach the files
it needs. Each bot keeps its own workspace and history so you can return to the work.

## Work as a team

Create a group, add the agents you need, and put the shared goal in its description.
Use the conversation to divide work, share findings, and review results together.
Each agent's public description helps others understand its role; its backstory
stays private.

Type `@` to insert an agent's name. Click its avatar to see its profile or open a
direct conversation. Right-click a group in the sidebar to change its members or
description. Removing a member keeps the group's history.

## Keep conversations in separate windows

Right-click a bot or group in the sidebar and choose **Open in New Window**.
Opening it again brings its existing window forward. Each separate window stays
on its conversation while you browse other chats in the main window.

Messages, unsent text, attachments, and conversation details update in both
places. Each window scrolls independently. Closing a window keeps the conversation
and its draft available in Noodle.

## Messages and files

- **Return** sends; **Shift+Return** adds a line.
- Use **+** to attach a file or choose a photo, or drag a file into the chat.
- Select an attachment and press **Space**, or double-click it, to preview it.
- Right-click a message to react. Right-click an image to use it as a background or, in a direct chat, the bot's icon.
- On supported macOS 26 Macs, use the microphone to send a [voice message](voice-messages.md).

Text supports Markdown. Switching chats keeps each chat's unsent draft.
Notifications open the matching conversation; a blue dot and the Dock badge mark
unread chats.

## Tools and computers

[Connect tools](mcp-connections.md) so agents can work with your services and data.
Add them in **Settings → Tools**, then assign them in the bot's **Tools** tab.
Add a [Noodle Computer](../Computer/README.md) in its **Computers** tab to give it
a Linux workspace. Several agents can share a computer to work on the same files.

## Heartbeats

Heartbeats let idle bots check for useful follow-ups on existing work. They are on
by default after 30 minutes. Change the interval or disable them for individual
bots in **Settings → Heartbeat**.

They run only while Noodle is open and the Mac is awake. A heartbeat can use model
tokens even when the bot has nothing to say; it does not authorize new work.
Noodle also attempts to resume interrupted work after a restart. Startup errors
and **Retry Startup** appear in **Settings → Security**.

## Shortcuts and settings

After launching Noodle once, search Spotlight for **Send Noodle Command** to send
a message without opening the chat window. The same action is available in Shortcuts.

**Settings → General** includes bot naming and **Keep Mac awake while agents work**.
**Settings → Chat** includes message delivery, the recording microphone, bot
descriptions in the @ menu, and link-preview timeout. See [agent access](security.md)
for permissions and [updates](releases.md#in-app-updates) for update settings.

[Documentation](README.md)
