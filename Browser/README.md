# Noodle Browser

Noodle Browser gives your bots persistent WebKit browsers on your Mac. Create a browser, open a website and sign in, then assign that browser in a bot's **Browsers** settings. The bot operates the same tabs and website data you see.

Browser is currently in development. It uses the suite's [shared release process](RELEASING.md), with its own version and download channel. Its first public download becomes available when its first release is published.

Each named browser has its own website data store. You can keep work, personal and unsigned browsing separate, or deliberately assign the same browser to several bots. Select browsers in the searchable sidebar; their tabs open in the same window. Closing the window leaves browsers running in the background. Quitting the app preserves website data and tab URLs; reopening reloads those URLs.

## Build and use

Requires macOS 26 or later, matching Noodle Computer, Apple's developer tools, and an Apple Development or Developer ID signing identity for local builds.

```sh
zsh scripts/build-browser.sh
zsh scripts/build-app.sh
open '.build/Noodle Browser Dev.app'
open '.build/Noodle Dev.app'
```

Builds default to separate Dev apps and storage. `NOODLE_BROWSER_DATA_CONTAINER=production` selects the production Browser identity; use the corresponding Noodle environment. Both variants can be installed together: names, bundle IDs, URL schemes, sandbox containers and broker App Groups are separate. Noodle Dev connects only to Noodle Browser Dev; normal Noodle connects only to normal Noodle Browser. To package both Browser variants in one command:

```sh
zsh scripts/build-browser.sh --both
```

Use `NOODLE_DATA_CONTAINER=production zsh scripts/build-app.sh` for matching normal Noodle. Set `NOODLE_BROWSER_APP_DESTINATION` when building a single Browser variant to stage it elsewhere without replacing a running app. A production build is not a published release. Browser uses the same Sparkle updater as Computer and Applet, with its own signed release feed. Local builds keep update checks disabled; release builds enable them with automatic installation opt-in.

1. In Noodle Browser, use **Create** in the toolbar or **File → New Browser…** and name it.
2. Enter a website address and sign in normally.
3. In Noodle, edit the bot, select **Browsers → Add Browsers**, choose the browser and save.
4. Ask the bot to work on that site. Noodle supplies its Browser skill and starts the companion quietly when needed.

**Pause Agents** prevents new agent operations while you use the browser. It does not undo an action already sent to a website. **Resume Agents** permits them again. Closing a tab removes it; deleting a browser removes its website data, tabs and stored files.

Browsers start muted. The public WebKit API implements this by suspending media playback, so video pauses too. New tabs and popups inherit that setting. The user can resume media with the speaker control. Camera and microphone capture are unavailable.

## Interface and settings

The native single-window layout follows Noodle Computer: searchable sidebar, circular profile icons, status indicators, persistent selection and sidebar visibility, shared wallpaper rendering, rounded content surface, and a unified native toolbar. Edit a browser from its sidebar context menu or the toolbar to change its name, icon, colour and background. Each browser owns its background; use **Background** in the editor or **Change Background…** in its context menu for the suite’s preset, file, Photos and Image Playground controls. Imported images, dynamic HEIC files and videos are copied into that browser’s private storage; videos play silently. Switching browsers switches the full window wallpaper, including beneath the sidebar. New browsers start with an available name such as “Browser 2”. Browsers retain their profile UUIDs, history, bookmarks and sign-ins through these edits.

Click the browser icon in its editor to open the suite’s icon dialog. Choose a symbol and colour, import an image from a file or Photos, or create one with Image Playground. Custom icon images are stored with that browser.

In Noodle’s bot editor, **Add Browsers** uses the same searchable assignment picker and removable icon grid as **Add Computers**. Custom browser icons appear there too.

Agents can send a page back with `browser present --browser UUID --tab UUID --conversation UUID --message "Open this page"`. The conversation gets a saved screenshot card and a `.noodlebrowser` file (`.noodlebrowser-dev` in Dev). Clicking the card or opening the file selects the original tab if it still shows the saved URL; otherwise it opens that URL in a new tab in the same persistent browser. A deleted browser stays deleted. The reference includes no cookies or agent credentials, and the preview is a captured image rather than a live embedded browser. Ordinary web links continue to open in the default browser. Agents can close individual tabs with `browser close --browser UUID --tab UUID`.

**Settings…** (⌘,) uses the suite’s General and Update tabs and shared settings layout. General selects the search engine and selection restoration. The application menu includes About and Check for Updates; File creates browsers and tabs; Browser provides navigation, history, bookmarks and downloads; View, Window and Help use the native menu structure.

## Browser commands

Runbar’s **Noodle Browser → Build & Launch Dev** runs `scripts/build-and-launch-browser.sh`, which always builds and opens the isolated Dev app. Quit a running Dev build before replacing it.

The managed command lives at `.agents/skills/browser/browser` in the bot's workspace. Run it with `--help` for the generated command reference. Commands return JSON and errors exit with status 1.

```sh
browser list
browser open --browser BROWSER_UUID --url https://example.com
browser inspect --browser BROWSER_UUID --tab TAB_UUID
browser fill --browser BROWSER_UUID --tab TAB_UUID --target '#search' --text 'annual report'
browser click --browser BROWSER_UUID --tab TAB_UUID --target 'button[type=submit]'
browser eval --browser BROWSER_UUID --tab TAB_UUID --text 'return document.title;'
browser upload --browser BROWSER_UUID --tab TAB_UUID --target 'input[type=file]' --source report.pdf
browser history --browser BROWSER_UUID --query example --limit 50 --offset 0
browser bookmarks --browser BROWSER_UUID
browser bookmark-add --browser BROWSER_UUID --url https://example.com --title Example
browser bookmark-update --browser BROWSER_UUID --bookmark BOOKMARK_UUID --title 'Example account'
browser bookmark-remove --browser BROWSER_UUID --bookmark BOOKMARK_UUID
browser downloads --browser BROWSER_UUID
browser download --browser BROWSER_UUID --download DOWNLOAD_UUID --output downloaded.pdf
browser screenshot --browser BROWSER_UUID --tab TAB_UUID --output screenshot.png
```

Use the full managed command path unless your shell already resolves `browser`. Navigation returns immediately; inspect the page or read status to determine readiness. `inspect` returns CSS selectors and frame IDs. JavaScript is an async function body; use `return` for a result. Frame IDs expire on navigation. `show` opens the human window for an explicit handoff.

Uploads and downloads pass directly through app storage, without Finder dialogs for the agent. Transfers support regular files up to 8 GiB. Local paths must remain inside that bot's workspace, parent directories must exist, and symlinks and overwrites are refused. Downloads stay in the browser; `download` copies a completed file to the workspace. Human file selection and exporting use standard macOS file panels. Interrupted downloads must be retried.

## Persistence and compatibility

Profiles use public `WKWebsiteDataStore(forIdentifier:)` APIs. Cookies, localStorage and IndexedDB persist in the app's own WebKit storage. Tab identities, URLs, selected tabs, download records and browser preferences are saved separately in the app's sandbox. Live DOM, the live tab’s back/forward stack and sessionStorage do not survive quitting. Downloads and uploaded files remain in per-browser folders until that browser is deleted.

Browsing history and bookmarks live in a separate SQLite database inside each browser’s private folder. History records successful HTTP(S) main-page visits (including reloads, back/forward and same-document URL changes), with title, URL and an ISO 8601 UTC visit time. Blank/internal pages, subframes and failed loads are excluded. History is retained until the user clears it or deletes the browser; clearing history keeps bookmarks and website sign-ins. This does not reconstruct visits from before history recording was added.

The toolbar’s Browser/History/Bookmarks/Downloads control switches the detail pane while keeping your browser sidebar available. The bookmark list has an Add button for the current page; its context menu edits or deletes entries. Agents can search both lists and add, edit or remove bookmarks by stable ID. Queries match titles and URLs, returning up to 200 records per page (50 by default), with `totalCount`, `limit` and `offset`. History is newest first; bookmarks are ordered by last edit. Pagination may shift while another tab or agent adds records. Pausing agent control permits reads and blocks bookmark mutations. Existing profiles keep their UUIDs and sign-ins; their record database is created on first use.

This is an embedded WebKit browser, not Safari. It does not share Safari or Chrome cookies, password stores, profiles or extensions. Websites can expire authentication, require MFA again, or reject embedded browsers. Some passkey, SSO, DRM and external-app flows may need capabilities beyond this initial version. Hidden pages may throttle animations or change their behavior based on visibility. Inspect supports ordinary DOM elements; JavaScript can handle custom widgets and open shadow roots. There is no browser-extension compatibility or WebDriver endpoint.

## Architecture and permissions

Noodle owns browser assignments and installs the managed skill and CLI. Agents write to their workspace mailbox; Noodle validates their active session and assignment on each request. A versioned protocol connects Noodle to the companion over a private Unix socket in a narrowly scoped App Group. Both endpoints verify the peer's signing team and exact app identity. Bots do not receive direct access to that socket or the shared file staging directory.

The Browser app uses App Sandbox, outbound networking, user-selected file access, and the Browser App Group. Like Computer and Applet, the signed Sparkle updater has only two additional Mach lookup grants, scoped to this app’s own installer endpoints (`<bundle-id>-spks` and `<bundle-id>-spki`). Its Installer, Autoupdate and Updater helpers are signed with the same team; the separate downloader is omitted. No general filesystem access is added. It does not require Accessibility, Apple Events, screen recording, Full Disk Access, or changing Safari's developer settings. Screenshots come from the web view; native input events are delivered to that view, not the system event stream. Operations are serialized per browser. A timeout never triggers an automatic replay of an action already sent.

## Verification

```sh
swift test --disable-sandbox --package-path Browser --scratch-path .build/browser
swift test --disable-sandbox --filter BrowserBrokerTests
zsh scripts/test-browser.sh
zsh scripts/test-browser-ui.sh '.build/Noodle Browser Dev.app'
```

`scripts/test-browser.sh` launches a loopback-only fake login/upload/download site, runs the signed app twice, saves screenshot artifacts under `.build/browser-verification`, and removes its test profiles. Set `NOODLE_BROWSER_TEST_NOODLE_APP` to a separately built Noodle app with the same Dev or normal identity to also verify its managed CLI and signed cross-app connection.

`Tests/Fixtures/server.py` provides the local site. The signed app's explicit `--smoke-test --smoke-id UUID --smoke-port PORT` mode uses isolated test profiles and stays out of the Dock. Run again with the same ID and `--restore` to verify authentication survives a process restart. Its signed broker uses a separate test socket, so a running browser can stay open. Test output reports the screenshot artifact path.

`scripts/test-browser-ui.sh` creates temporary profiles and checks the real sidebar, native toolbar, clicks in tab padding, independent tab closing, live page input, background screenshots, edit and icon sheets, application menus, Settings scene and Update tab. It saves native-window snapshots under `.build/browser-ui-verification`, including collapsed-sidebar content, tests deletion while the window is mounted, and removes its fixture profiles. This mode does not operate profiles from the browser library or start its provider socket.
