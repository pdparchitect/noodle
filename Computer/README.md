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
and services. Each gets its own terminal sessions. An agent can present a terminal
or desktop in the conversation for you to review work or take over a step.
Closing a preview leaves the terminal running.

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

## Customize and update

Edit a computer to change its icon, background, and terminal colours. Backgrounds
support images, animated HEIC, and muted looping video.

Choose **Update** from the computer's context menu or editor to fetch its latest
image. The computer stops during the update and restarts afterward. Your files
and installed software are preserved; modified system files can override updated
defaults. A failed update leaves the active disk unchanged. Older flat-disk
computers do not support this update layout.

App updates are separate, under **Settings → Update**. Save guest work first;
computers are stopped and are not automatically restarted after the app relaunches.

## Custom images

Choose **New from Container Image…** and enter a public ARM64 OCI image reference.
The image must contain `/bin/sh`. Without a web port, it opens as a shell. With a
web port, Computer runs the image's application command and displays its web app.
The service must listen on the guest network interface, not only localhost.
Private registry credentials and Compose are not supported.

## Access and storage

Each computer runs in its own virtual machine. Host folders and clipboard are not
shared; file transfers are explicit. Guest networking can reach your LAN. You can
disable it for Shell computers; Desktop requires it.

Closing the window keeps computers running. Quitting stops them. Deleting a
computer requires confirmation and moves its stopped disk to Trash.

[Build and test](DEVELOPMENT.md) · [Noodle integration](Bridge/README.md) ·
[Images](Images/README.md) · [Releases](RELEASING.md) · [Changelog](CHANGELOG.md) ·
[Noodle](../README.md)
