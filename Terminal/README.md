# Noodle Terminal

[![macOS 26 ZIP](https://img.shields.io/badge/macOS_26-ZIP-0A84FF?logo=apple&logoColor=white)](https://github.com/pdparchitect/noodle/releases/download/terminal-latest/Noodle-Terminal-arm64.zip) [![Linux arm64](https://img.shields.io/badge/Linux-arm64-E95420?logo=linux&logoColor=white)](https://github.com/pdparchitect/noodle/releases/download/terminal-latest/Noodle-Terminal-linux-arm64.tar.gz) [![Linux x86_64](https://img.shields.io/badge/Linux-x86__64-E95420?logo=linux&logoColor=white)](https://github.com/pdparchitect/noodle/releases/download/terminal-latest/Noodle-Terminal-linux-x86_64.tar.gz) [![Windows arm64](https://img.shields.io/badge/Windows-arm64-0078D4?logo=windows&logoColor=white)](https://github.com/pdparchitect/noodle/releases/download/terminal-latest/Noodle-Terminal-windows-arm64.zip) [![Windows x86_64](https://img.shields.io/badge/Windows-x86__64-0078D4?logo=windows&logoColor=white)](https://github.com/pdparchitect/noodle/releases/download/terminal-latest/Noodle-Terminal-windows-x86_64.zip)

Chat with the bots and groups on your Noodle Hub from Terminal on your Mac, without the
Noodle app. One conversation fills the window, newest message at the bottom, with the
message field under it. Everything else is a command: type `/` to see them.

## Installing

### On a Mac

Noodle Terminal needs macOS 26 on a Mac with Apple silicon.
The [Noodle Suite Installer](https://github.com/pdparchitect/noodle/releases/download/suite-latest/Noodle-Suite-Installer.pkg)
can install it for you: check Noodle Terminal in its list of apps, and the `noodle` command goes
in `/usr/local/bin`, which is already on your `PATH`. Or
[download Noodle-Terminal-arm64.zip](https://github.com/pdparchitect/noodle/releases/download/terminal-latest/Noodle-Terminal-arm64.zip)
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

Copying puts text on the clipboard of the computer the terminal shows on, where the terminal allows it.

### On Windows

Noodle Terminal runs on Windows 10 and 11 on arm64 or x86_64, in Windows Terminal. Download it for
[arm64](https://github.com/pdparchitect/noodle/releases/download/terminal-latest/Noodle-Terminal-windows-arm64.zip)
or [x86_64](https://github.com/pdparchitect/noodle/releases/download/terminal-latest/Noodle-Terminal-windows-x86_64.zip).
The ZIP holds a `Noodle Terminal` folder with `noodle.exe` and everything it needs, including Microsoft's
msquic and the Swift runtime, so nothing else needs installing; keep the folder's files together. In PowerShell:

```
Expand-Archive "$HOME\Downloads\Noodle-Terminal-windows-*.zip" "$env:LOCALAPPDATA\Programs"
& "$env:LOCALAPPDATA\Programs\Noodle Terminal\noodle.exe"
```

`noodle.exe` is not signed yet, so when you first start it from Explorer, Windows SmartScreen asks
first: choose **More info**, then **Run anyway**. Starting it from PowerShell, as above, does not ask.

To run it as `noodle`, add that folder to your `PATH` in **Settings → System → About → Advanced system
settings → Environment Variables**. To update, download the ZIP again and replace the folder.

Links and files open with the apps Windows chooses for them, and copying uses Windows Terminal's
clipboard.

### Building it

To build it from this repository instead, with Swift 6.4 (on a Mac, Xcode 27):

```
swift build -c release --package-path Terminal
Terminal/.build/release/noodle
```

## Joining your Hubs

The first time, Noodle Terminal asks for an invitation. On a device already paired with
your Hub, invite another device, then paste the invitation link or code into the message
field and press Return. To join another Hub, such as a friend's, type `/join` and the link.

The bots and groups of every Hub you join are together in All. `/space` shows one Hub's
instead, or All again, and Control-O goes to the next. `/hubs` lists your Hubs and whether
they're connected; choose one to pair another device, manage its users if you're an admin,
choose how groups notify you, or leave it.

## Commands

Type `/` and the commands appear under the message field. Keep typing to narrow them, use
Up and Down to choose, Tab to complete, and Return to run. A name after the slash finds
bots and groups too: `/sc` and Return opens Scout. `/help` lists every command.

Conversations:

- `/switch` and a name goes to a bot or group; on its own, it lists them. `/bots` and
  `/groups` list just those.
- `/search` and some words finds bots and groups by name and messages by what they say,
  including older ones. Choose a message to go to it.
- `/earlier` loads earlier messages.
- `/pin` and `/unpin` keep a bot or group at the top on all your devices; `/archive` takes
  it off the list, and `/archived` brings it back.
- `/notify` chooses how a group notifies you.

Messages: press Up with the message field empty to choose the newest message, and Up and
Down to choose another. These act on the chosen message, or the newest:

- `/copy` copies it, and `/react` adds or takes back a reaction.
- `/open` opens one of its links or files, and `/save` saves a file to Downloads.
- `/retry` sends a message that didn't go through again, and `/discard` deletes it.
- `/file` and a path sends a file. You can drop a file on the window to type its path.

Bots and groups:

- `/new bot` and `/new group` make one, asking one thing at a time in the message field.
  Return accepts each answer, and Escape stops.
- `/edit` changes the name and description, a bot's backstory and a group's bots;
  `/delete` deletes it, after asking.
- `/harness`, `/model`, `/effort`, `/colour` and `/symbol` change a bot's harness, model,
  effort, colour and symbol. `/members` chooses a group's bots.
- `/tools`, `/computers` and `/browsers` choose what a bot can use, and `/share` who else
  can talk to it. In these lists, Space checks and unchecks, and Return saves.
- `/session` starts a bot on a fresh context, `/organize` asks it to tidy its workspace and
  memory, and `/kick` starts it again when it's stuck.

Hubs: `/join`, `/hubs`, `/pair` to invite another of your devices, and `/users` to manage
the people on your Hub if you're its admin. `/quit` leaves Noodle Terminal.

To send a message that starts with a slash, type two.

## Keys

- Return sends what you typed. Control-J starts a new line.
- Escape closes a list, stops a form, or leaves the chosen message.
- Page Up and Page Down scroll, and so does the mouse wheel; End goes back to the newest.
- Control-U clears what's before the cursor, and Control-W the word before it.
- Control-C clears the message field, or quits when it's empty.

The app uses the mouse wheel, so to select text with the mouse, hold Shift or Option while
you drag, whichever your terminal uses.

Messages show their formatting: bold, italics, code, lists and quotes, and links with where
they go. Files are listed under their message; open or save them with `/open` and `/save`.
