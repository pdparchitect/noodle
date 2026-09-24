# Working with agents

Use Noodle to give work to an AI agent or bring several agents together around a
common goal. Conversations hold the instructions, progress, and results.

## Give an agent a job

On first launch Noodle [sets up your first bot](harness-setup.md) with you. After
that, create a bot, choose its [harness](harness-setup.md), and use the backstory to define
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

The picture in a separate or floating window's title carries the bot's status
dot: blue while it works, green when ready, red after a failure. Click **Show in
Main Window** in the title bar to close the window and continue the conversation
in the main window.

## Float a conversation over other apps

Right-click a bot or group in the sidebar and choose **Float on Top** to open it
as a floating window. To switch a separate conversation window that is already
open, choose **Float on Top** from its **Conversation Info** menu. The window
stays above other apps, on every Space and over full-screen apps, and can be made
smaller than a normal window. Typing in it does not bring Noodle's other windows
forward. It floats again after you relaunch Noodle.

For the chat in the current window, the **Conversation** menu has the same
**Open in New Window** and **Float on Top** commands.

A floating window blurs what is behind it in place of the conversation
background. Its only window control is the close button, and it has no
Conversation Info menu. Drag its header to move it. Closing it ends floating, and
**Open in New Window** in the sidebar returns it to a normal window.

Press ⌃⌥Space in any app, or choose **Conversation → Choose Conversation…**, to
pick a bot or group from a grid. Type to filter, move with the arrow keys, press
Return to choose and Escape to cancel. Conversations that are already floating
come first and carry a badge, so the grid also switches between them. A blue dot
before a name marks unread messages. The conversation opens as a floating window
by the pointer, or where you last left it, ready for typing. Capture and
annotations work there as in any chat window, so you can share what is on screen
without going back to Noodle. Change the shortcut in **Settings → Keybindings**.

Several conversations can float at once. To keep a single float, turn on
**Settings → Conversation → Keep one floating conversation**: floating another
conversation then closes the open one and takes its exact place and size.

## Watch an agent’s activity

Right-click a bot in the sidebar or its avatar in a conversation and choose
**Show Activity**. Each bot has one floating log window showing its runtime
status, tool activity, and output across direct and group conversations.
Drag the header to move it, resize it from its edges, and close it with the close control, **Esc**, or **⌘W**.

Scroll up or select text to pause automatic following. Right-click the log for
**Copy**, **Copy All**, **Select All**, **Follow Latest**, and **Clear**.
Selected text also supports the standard **⌘C** shortcut.
Recent activity is kept while Noodle is open, even with the window closed. Older
entries and long output are trimmed. Quitting Noodle clears the log.

Available detail depends on the harness. Apple currently reports working and
lifecycle status; other harnesses also expose tool activity and text output.

## See what your bots spend

Choose **Noodle → Usage** (**⇧⌘U**) to chart token use over the last 7 days,
30 days or 12 months. Stack the bars by bot, harness or model, switch between
tokens and cost, and hover a bar for that day's figures. The table below the
chart breaks the period down by input, output and cached tokens. To see one bot,
pick it from the menu at the top left, or open its profile and click **Usage**.

History is kept across restarts and after a bot is deleted. Claude Code and
Codex report usage; Claude Code also reports cost. Other harnesses are not
counted yet.

## Messages and files

- **Return** sends; **Shift+Return** adds a line.
- Use **+** to attach a file or choose a photo, or drag a file into the chat.
- Click an attachment or select it and press **Space** to preview it. Noodlet links open their live creation in Noodle Applet.
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

The **Tools** tab also assigns the calendars and reminder lists on this Mac. A bot can
read the ones you give it and add, change and delete entries in them; anything you
leave unassigned stays invisible to it. macOS asks for access the first time —
calendars and reminders are separate permissions — and you can withdraw either in
System Settings.

## Heartbeats

Heartbeats let idle bots check for useful follow-ups on existing work. They are on
by default after 30 minutes. Change the interval or disable them for individual
bots in **Settings → Heartbeat**. Click the **Heartbeat** heading above the bot
switches for an explanation.

They run only while Noodle is open and the Mac is awake. A heartbeat can use model
tokens even when the bot has nothing to say; it does not authorize new work.
Noodle also attempts to resume interrupted work after a restart. Startup errors
and **Kick** appear beside the affected bot in **Settings → Harness**. Kick is also
available from the bot's sidebar menu; review any recovery confirmation first.

## Shortcuts and settings

After launching Noodle once, search Spotlight for **Send to Agent**, choose an
**Agent or Group**, and enter a **Message**. The same action is available in
Shortcuts. Replies appear in the chosen conversation in Noodle.

To send selected text or files from another app, choose **Services → Send to Agent…**
and select the agent or group that should receive them.

**Settings → General** includes bot naming and **Keep Mac awake while agents work**.
**Settings → Conversation** includes message delivery, the recording microphone, bot
descriptions in the @ menu, and link-preview timeout. See [agent access](security.md)
for permissions and [updates](releases.md#in-app-updates) for update settings.

[Documentation](README.md)
