# Noodle Applet

Noodle Applet is a macOS companion to Noodle for little tools, websites,
experiments and games. Each one is a noodlet: a small creation your bots write
and you open like an app. In Finder a noodlet looks like a single document.

## Get it

Download Noodle Applet from the
[`applet-latest` release](https://github.com/pdparchitect/noodle/releases/tag/applet-latest).
It needs macOS 15 or later. Once it is installed, your bots in Noodle can use it
straight away; remove it and they stop. Noodle does not open Applet until a bot
needs it or you open it yourself.

Noodlets written in Swift also need Xcode or Apple's Command Line Tools installed
on your Mac. With Command Line Tools alone, some SwiftUI features are not
available. Web noodlets need neither.

## The library

Opening Noodle Applet shows your library of noodlets. The **All**, **Recent**,
**Pinned** and **Hidden** tabs sort them. Right-click a noodlet's card to pin it,
hide it, or reveal its files in Finder. Noodlets your bots make appear in the
library on their own.

To add a noodlet you already have, choose **File → Open Noodlet…** or double-click
it in Finder. If you delete it later, it leaves the library too. Press Space on a
noodlet in Finder for a quick preview; open it in Applet for the full, interactive
version with its saved data.

Applet can also sit in the menu bar. Turn this on in the General settings.

## Play on a TV

A noodlet can play full screen on another display, such as an Apple TV or a
TV that supports AirPlay. First add the TV as a separate display: choose
**File → Play On → Add TV or Display…**, then pick the TV from the add menu in
Displays settings. Then, with the noodlet in front, choose the TV from
**File → Play On**. You can also right-click a running noodlet's card in the
library. To end it, choose **Bring Back to This Mac** or leave full screen.
Keyboards, mice and trackpads stay connected to the Mac.

A noodlet whose window can be resized fills the TV. One made at a fixed size,
such as a game, keeps its shape: it is scaled up as far as it fits and centred,
with black around it.

## What bots can do

Bots build noodlets, open and use them, take screenshots, and record short videos
of them with sound. A noodlet running out of sight stays silent; only one in front
of you plays sound. Recording a noodlet never asks for screen recording access.

A bot can share a noodlet in a conversation as a link. Clicking the link opens the
live noodlet in Applet, with full interaction and saved data, or brings its window
forward if it is already open. Links point to the noodlet on this Mac; they are not
copies you can send elsewhere.

Bots and terminal users can run `noodlet --help` to list the commands.

## Permissions and privacy

A noodlet that needs the microphone, camera, speech recognition or screen capture
asks you once before it starts, and then macOS asks for Noodle Applet as a whole.
If you decline, the noodlet does not open. A new screen recording grant takes
effect after Applet restarts.

In Settings:

- **Permissions** lists what each noodlet was allowed and lets you take it back,
  so the noodlet asks again.
- **Secrets** lists the names of keys and tokens each noodlet has saved, never
  their values, and removes them. A noodlet can only reach its own secrets.
- **Storage** shows each noodlet's saved data and removes it.

A Swift noodlet cannot reach your files, other noodlets or your Keychain. Files go
in and out only through the open and save dialogs you see.

## Updates

Choose **Applet → Check for Updates…**, or use **Settings → Update**.
**Help → Noodle Applet Help** opens the project page.

See [release preparation](RELEASING.md) and the [changelog](CHANGELOG.md).
