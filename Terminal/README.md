# Noodle Terminal

[![macOS 26 ZIP](https://img.shields.io/badge/macOS_26-ZIP-0A84FF?logo=apple&logoColor=white)](https://github.com/pdparchitect/noodle/releases/download/terminal-latest/Noodle-Terminal-arm64.zip) [![Linux arm64](https://img.shields.io/badge/Linux-arm64-E95420?logo=linux&logoColor=white)](https://github.com/pdparchitect/noodle/releases/download/terminal-latest/Noodle-Terminal-linux-arm64.tar.gz) [![Linux x86_64](https://img.shields.io/badge/Linux-x86__64-E95420?logo=linux&logoColor=white)](https://github.com/pdparchitect/noodle/releases/download/terminal-latest/Noodle-Terminal-linux-x86_64.tar.gz)

Chat with the bots and groups on your Noodle Hub from Terminal on your Mac, without the
Noodle app. Your bots and groups are listed on the left with their pictures, newest
conversation first, with pinned ones on top and a dot on the unread ones. The
conversation you choose is on the right, with the bots' messages on the left and yours on
the right, each in its own bubble.

Pictures show as they are in terminals that can show images, such as Ghostty, kitty,
WezTerm and iTerm2. Other terminals, including Terminal, show them in coloured blocks.

## Installing

### On a Mac

Noodle Terminal needs macOS 26 on a Mac with Apple silicon.
[Download Noodle-Terminal-arm64.zip](https://github.com/pdparchitect/noodle/releases/download/terminal-latest/Noodle-Terminal-arm64.zip)
and open it to get the `noodle` command. Move it to a folder on your `PATH`, then run it:

```
mkdir -p ~/.local/bin
mv ~/Downloads/noodle ~/.local/bin/
noodle
```

If `~/.local/bin` isn't on your `PATH` yet, add `export PATH="$HOME/.local/bin:$PATH"`
to `~/.zshrc`. To update, download the ZIP again and replace the command.

### On Linux

Noodle Terminal runs on Linux on arm64 or x86_64, in any terminal, and over SSH too. Download it for
[arm64](https://github.com/pdparchitect/noodle/releases/download/terminal-latest/Noodle-Terminal-linux-arm64.tar.gz)
or [x86_64](https://github.com/pdparchitect/noodle/releases/download/terminal-latest/Noodle-Terminal-linux-x86_64.tar.gz).
It needs msquic, from Microsoft's packages; on Ubuntu 24.04:

```
sudo apt install curl
curl -fsSL https://packages.microsoft.com/config/ubuntu/24.04/packages-microsoft-prod.deb -o /tmp/microsoft.deb
sudo dpkg -i /tmp/microsoft.deb && sudo apt update && sudo apt install libmsquic
```

Then put the `noodle` command on your `PATH` and run it:

```
tar xzf Noodle-Terminal-linux-*.tar.gz
mkdir -p ~/.local/bin
mv noodle ~/.local/bin/
noodle
```

Bots show their colours, without the symbols they have on a Mac. Copying puts text on the clipboard
of the computer the terminal shows on, where the terminal allows it.

### Building it

To build it from this repository instead, with Swift 6.4 (on a Mac, Xcode 27):

```
swift build -c release --package-path Terminal
Terminal/.build/release/noodle
```

## Joining your Hubs

The first time, Noodle Terminal asks for an invitation. On a device already paired with
your Hub, invite another device, then paste the invitation link or code and press
Return. To join another Hub, such as a friend's, press Control-N.

The bots of every Hub you join share one list, All. Click a Hub's name above a
conversation to show one Hub's bots and groups instead, or All again; Control-O goes to
the next space. Hubs in the command palette shows each Hub, whether
it's connected, and lets you pair another device, manage its users if you're an admin,
choose how groups notify you, or leave it.

## The command palette

Control-K shows everything you can do for the bot or group you chose, and for the
message you chose in it. Type to narrow it down, use Up and Down to choose, and press
Return. From there you can:

- pin or unpin, archive, and bring back archived bots and groups;
- choose how a group notifies you;
- make, edit and delete bots and groups, and choose a bot's harness, model, colour and
  symbol;
- choose the tools, computers and browsers a bot can use, and who it's shared with;
- start a new session for a bot, organize it, or kick it when it's stuck;
- send a file from your Mac, open or save a message's file or link, copy a message, react
  to it, or try again or delete a message that didn't go through.

## Keys

- Tab moves between the search field, the list, the messages and the message field; the
  one you're in has a highlighted outline. Shift-Tab goes the other way.
- Up and Down choose a bot or group; Return goes to its message field, and so does just
  starting to type.
- In the messages, Up and Down go from message to message, Page Up and Page Down scroll,
  and Home and End go to the start and the newest. Each conversation stays where you left
  it.
- Return in the message field sends what you typed. Click the message field to type there.
- Escape goes back to the list, or closes a screen.
- Control-F searches. Bots and groups are found by name, and messages by what they say,
  including ones this Mac hasn't loaded.
- Control-L goes to the list.
- Control-C quits.

You can also click and scroll with the mouse where your terminal allows it. Pictures sent
in a conversation show under their message, and messages show their formatting: bold,
italics, code, links, lists and quotes. Click a link to open it in your browser.
