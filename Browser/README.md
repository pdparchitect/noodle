# Noodle Browser

Noodle Browser gives your bots web browsers on your Mac that remember where they
were and who they are signed in as. Create a browser, open a website and sign in,
then assign that browser to a bot in Noodle. The bot works in the same tabs and
signed-in accounts you see.

Noodle Browser is still in development. It will be available to download once
its first release is published. It requires macOS 26 or later and works together
with Noodle.

## Get started

1. In Noodle Browser, choose **Create** in the toolbar or **File → New Browser…**
   and give the browser a name.
2. Enter a website address and sign in as you normally would.
3. In Noodle, edit a bot, choose **Browsers → Add Browsers**, pick the browser
   and save.
4. Ask the bot to work on that site. Noodle starts Noodle Browser in the
   background when the bot needs it.

## Browsers

Each browser keeps its own sign-ins and website data, so you can keep work,
personal and signed-out browsing apart. You can also give the same browser to
several bots on purpose.

Pick a browser in the searchable sidebar to see its tabs. Closing the window
leaves your browsers running in the background. When you quit, your sign-ins and
open pages are kept, and the pages reload when you open the app again. A page's
back and forward history and anything you were typing into it are not kept.

Closing a tab removes it. Deleting a browser removes its sign-ins, tabs, history,
bookmarks and files.

### Pause Agents

**Pause Agents** stops bots from doing anything new in a browser while you use it
yourself. It cannot undo something a bot already did on a website. Bots can still
read history and bookmarks while paused. **Resume Agents** lets them continue.

### Sound and media

Browsers start muted, and muting also pauses video. New tabs and pop-ups follow
the same setting. Use the speaker button to turn sound and playback back on.
Websites cannot use your camera or microphone.

### History, bookmarks and downloads

Use the Browser, History, Bookmarks and Downloads control in the toolbar to switch
views. History lists the pages you and your bots visited until you clear it or
delete the browser; clearing history keeps bookmarks and sign-ins. Add the current
page with **Add** in the bookmark list, and right-click a bookmark to edit or
delete it. Bots can search both lists and manage bookmarks too.

Downloads stay inside that browser until you save them to your Mac or a bot
copies them into its own work area. Interrupted downloads must be started again.

## Customize

Edit a browser from its right-click menu in the sidebar or from the toolbar to
change its name, description, icon, colour and background.

- The optional description, up to 500 characters, says what the browser is for,
  such as which account it is signed in to. Bots see it with the name and use it
  to pick the right browser. It is not shown on page cards in conversations.
- Click the icon in the editor to choose a symbol and colour, use an image from a
  file or Photos, or create one with Image Playground.
- Choose **Background** in the editor or **Change Background…** in the right-click
  menu for a preset, a file, a photo or an Image Playground image. Moving
  backgrounds and videos play silently. Each browser has its own background.

Renaming or restyling a browser keeps its sign-ins, history and bookmarks.

**Settings…** (⌘,) lets you choose the search engine and whether the last browser
is selected when the app opens. **Check for Updates** is in the app menu and under
**Settings → Update**.

## What bots can do

An assigned bot can open pages, read them, fill in forms, click, upload and
download files, take screenshots, and use history and bookmarks. It uploads only
files from its own work area and saves downloads there. Files can be up to 8 GB.

While a bot works, you can watch it in the browser window. A cyan target marks
where the bot is pointing in each tab. It can hover over menus and click, but it
does not move your own pointer or take focus from the app you are using. Bots
cannot drag or right-click. Your own clicks, navigating, pausing agents or closing
the tab reset the bot's pointer.

Some websites offer tools made for AI agents. Bots can find and use these in a
signed-in tab, in the background, without extra setup. This support is
experimental. A form that needs your confirmation is left filled in for you to
submit. Bots treat what a website says about its tools as untrusted and act only
on your request.

### Pages in conversations

A bot can send a page back to the conversation as a card with a screenshot.
Clicking the card opens that page in the same browser, in its original tab if it
is still there. The card does not carry your sign-ins, and the screenshot is a
picture, not a live page. A deleted browser cannot be brought back from a card.

## Limits

This is a built-in web browser, not Safari. It does not share Safari or Chrome
sign-ins, passwords, profiles or extensions, and browser extensions are not
supported. Websites may sign you out, ask for two-factor codes again, or refuse to
work in it. Some passkey, single sign-on, protected video and open-in-app flows
may not work yet. Pages in background tabs may slow down or behave differently.

Noodle Browser does not need Accessibility, Screen Recording, Full Disk Access or
Safari settings. It opens files only when you choose them.

[Changelog](CHANGELOG.md) · [Releases](RELEASING.md) · [Noodle](../README.md)
