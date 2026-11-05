# Changelog

## [Unreleased]

### Security

- Noodle Terminal no longer serves itself to web browsers. The terminal framework it is built with started a hidden companion page on a local port whenever it ran, and any program running as you could get the page's address and control Noodle Terminal through it; with `--web --bind` it listened on every network interface. Neither is built in any more, whatever the options or environment say.

### Added

- Noodle Terminal: chat with the bots and groups on your Noodle Hub from Terminal on your Mac. Join a Hub with an invitation, see your bots and groups with unread dots and pins, read and send messages, load earlier ones, and search bots, groups and messages.
- Bots and groups show their pictures, and pictures sent in a conversation show under their message. Terminals that can show images show them as they are; others show them in coloured blocks.
- Join several Hubs and switch between All and one Hub's bots and groups with Control-O. Hubs shows each one, pairs another device, manages users for admins, sets how groups notify you, and leaves a Hub.
- Control-K opens a command palette for the chosen bot, group or message: pin, archive, notifications, Kick, New Session, Organize, editing and deleting, tools, computers, browsers, sharing, sending a file, opening or saving a message's file, copying, reactions, and trying a message again.
- Make and edit bots and groups: name, description, backstory, harness, model, effort, colour and symbol.
- Messages show their markdown: headings and bold, italics, code, links, lists, quotes and code blocks. Click a link to open it in your browser, or open it from the command palette.
- Text fields keep a quiet grey border until you type in them, then a heavy one in the accent colour. The message field is a plain line under the messages, and typing in the list or the messages starts a message there.
- The list, the messages and the message field show which one has the keys, and Tab goes between them. Messages scroll with Page Up, Page Down, Home and End, and each conversation keeps its place. Clicking a Hub's name above a conversation lists the spaces to choose from.
- Messages show in bubbles, the bots' on the left and yours on the right in another colour, and the list reaches the bottom of the window.
