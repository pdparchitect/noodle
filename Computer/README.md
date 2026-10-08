# Noodle Computer

**Linux computers for you and your AI agents.**

Give agents a place to run tools and work on files. Choose a desktop with a browser,
terminal, and file manager, or a lightweight shell. Files and installed software
stay with each computer across restarts. No Docker Desktop installation is needed.

<p>
  <img width="32%" alt="Noodle Computer screenshot 1" src="https://github.com/user-attachments/assets/5eb21524-90e3-4eaa-830f-ff2873db3932" />
  <img width="32%" alt="Noodle Computer screenshot 2" src="https://github.com/user-attachments/assets/bc262efa-51fa-474c-9c5e-1560a7fce52b" />
  <img width="32%" alt="Noodle Computer screenshot 3" src="https://github.com/user-attachments/assets/f4b95e1d-420c-4c00-ad4b-bfb71168860f" />
</p>

## Get started

Requires an Apple silicon Mac running macOS 26 or later.

1. [Download Noodle Computer](https://github.com/pdparchitect/noodle/releases/tag/computer-latest), unzip it, and move the app to **Applications**.
2. Open the app and create a **Desktop** or **Shell** computer.
3. Start it and use the toolbar to switch between Desktop, Terminal, and Files.

Advanced Options lets you adjust CPU, memory, disk size, and networking. Creating
a computer downloads its image, so you need an internet connection.

## Give agents a computer

In Noodle, create or edit a bot and add a computer in its **Computers** tab.
Noodle starts the Computer app when needed; its window can stay closed.

Assign the same computer to several agents when they need to work on shared files
and services. Each gets its own terminal sessions. Agents can copy files between
their work area and the computer, up to 8 GB each.

An agent can show you a terminal or desktop in the conversation as a link with a
picture of what it showed. Click the link to select and start that computer in
Noodle Computer. You get the computer's normal desktop or terminal, not the
agent's own session. Closing the window leaves the computer running.

## Use the terminal

Shell and Desktop images use the non-root `agent` account, with passwordless
`sudo` for administrative work (for example, `sudo apk add jq` in Shell).
Older images may still use root; choose **Upgrade** to get the current
account setup. Files created earlier by root keep their owner; use `sudo` to
manage them.

The commands available are the ones in the image plus any packages you install.

**Command-K** clears earlier output while preserving the current input. You can
also right-click and choose **Clear Terminal**. In full-screen applications, this
clears scrollback while preserving the application’s screen.

**Control-C** interrupts a command while the terminal has focus. You can also
right-click in the terminal and choose **Interrupt Command**. **Command-C** remains
Copy. Shells with line editing support also provide
**Control-L** to redraw, **Up/Down** for history, **Control-A/E** for the start/end
of the line, **Option-Left/Right** for word movement, and **Tab** for completion.

## Work with files

**Files** opens at `/workspace`. Browse in icons, list, or gallery view. Press
**Space** to preview a supported image, PDF, or text file; **Command-F** searches,
**Command-Shift-G** opens a folder path, and **Return** renames the selection.

Drag files or folders from Finder onto a folder to import into it, or onto empty
space to import into the open folder. You can also use
**Import Files or Folders…** in the actions menu. Imports preserve nested, hidden,
and empty folders, with a progress bar and **Cancel** button. Cancelling stops the
current transfer; completed items stay in the computer. Symbolic links and special
files cannot be imported or exported. Imports do not overwrite or merge existing items.

Drag files or folders out to Finder, or choose **Export…**, to copy them to your Mac.
Exports show progress and can be cancelled; incomplete exports are discarded.

Drag an item onto another folder inside Computer to move it. The native **+** cursor
indicates a copy in or out; internal moves have no **+** badge. Each file can be up to 8 GB.
Previews support files up to 20 MiB. Editing a preview copy does not update the guest file.

Right-click to rename, duplicate, or permanently delete a file or empty folder.

## Customize and upgrade

Edit a computer to change its name, description, icon, background, and terminal
colours. Backgrounds support images, animated HEIC, and muted looping video.
While a computer is stopped, you can also change its CPUs, memory and networking;
the disk capacity is set when the computer is created.

The optional description (up to 500 characters) says what the computer is for,
such as which project it builds. Assigned bots see it with the name and use it to
choose the right computer. It is not shown on preview cards in conversations.

A Desktop computer keeps its own screen resolution and scales to fit its window.
Turn on **Resize desktop with window**, when creating the computer or in its editor,
to make the desktop follow the window's size instead.

Choose **Upgrade** from the computer's context menu or editor to fetch its latest
image; the list shows **Upgrade available** when there is one. The computer stops
during the upgrade and restarts afterward. Your files and installed software are
preserved; modified system files can override upgraded defaults. A failed upgrade
leaves the computer as it was. Some older computers cannot be upgraded this way.
A Desktop computer on an older image must be upgraded before it starts.

App updates are separate, under **Settings → Update**. Save guest work first;
computers are stopped and are not automatically restarted after the app relaunches.

## Automate the desktop browser

The Desktop computer's browser keeps its sign-ins across restarts. Sign in to a
website there and an assigned agent can work in the same tabs from the computer's
terminal. Every agent assigned to that computer can use those sign-ins. Pause
agents while you sign in, and choose **Upgrade** on older computers to get this.

## Local Mac (experimental)

**Local Mac**, in the same menus as **New Linux Container**, gives agents a desktop on
this Mac instead of a Linux computer. It runs as a separate standard macOS account
signed in in the background, with its own desktop, terminal and files. It shares
your Mac's processor, memory and network, and it is not isolated like a virtual
machine: its terminal can reach whatever macOS lets that account reach.

The first time, choose **Enable Local Mac** and approve it in **System Settings →
Login Items**. Inside the Local Mac account, allow **Noodle Local Mac Desktop**
under **Screen Recording** and **Accessibility** so Computer can show and control
its desktop. The computer's settings point you to the right app. Its Desktop,
Documents and Downloads folders, and scripts that control other apps, ask for
permission in that account the usual macOS way.

- **Focus Window** opens the account's front window in its own resizable window
  on your Mac. **Open All Windows** does the same for every visible window and
  tiles them. Closing one leaves the app running in the account.
- Press **Control-Option-Escape** to release the keyboard from the Local Mac
  desktop. Command-Tab always goes to your own Mac.
- **Stop** signs the account out and keeps it. If nothing has connected to it for
  five minutes, for example after Computer quit unexpectedly, it is signed out
  automatically.
- **Delete** removes the account and its files after you confirm. If macOS blocks
  this, Computer offers to open Full Disk Access for it.
- If Local Mac stops responding after an update, choose **Repair Local Mac** in
  Setup. Your accounts, files and permissions are kept.

Agents can use the terminal and files and show the desktop in a conversation, but
cannot yet click or type on the desktop.

## Windows (experimental)

**New Windows**, in the same menus, makes a Windows 11 for Arm computer. It needs
macOS 27 or later.

The first Windows computer downloads Windows from Microsoft (about 5 GB) and
installs it, which takes about half an hour while it shows its progress. Computer
keeps that installation, so each later Windows computer needs only a few minutes of
setup the first time it starts. Windows sets itself up without a network, then
restarts with one.

- Click the desktop to give Windows your keyboard and mouse.
- **Terminal** opens PowerShell, and **Files** starts in your Windows home folder,
  with every drive one level up. Both open once Windows has signed in.
- The desktop is 1024 × 768 for now.
- **Stop** shuts Windows down; **Force Stop** turns it off.
- Windows is not activated. To activate it, enter your own product key in
  Windows' Settings.
- Agents can use the terminal and files and show the desktop in a conversation,
  but cannot click or type on it.

## Access and storage

Each Linux computer runs in its own virtual machine. Host folders and clipboard are not
shared; file transfers are explicit. Guest networking can reach your LAN. You can
disable it for Shell computers; Desktop requires it.

Closing the window keeps computers running. Quitting stops them. Deleting a
computer requires confirmation and moves its stopped disk to Trash.

[Releases](RELEASING.md) · [Changelog](CHANGELOG.md) · [Noodle](../README.md)
