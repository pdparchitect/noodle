# Noodle Applet

A separate macOS companion for little tools, websites, experiments, and games.
Noodlets are ordinary folders ending in `.noodlet`, displayed as document packages
in Finder. The app provides an interactive viewer and a visual library; agents
write the source files using their usual tools.

## Build and run

Requires macOS 15+, Swift 6, and an Apple Development or Developer ID signing
identity. From the repository root:

```sh
scripts/build-applet.sh
open '.build/Noodle Applet.app'
swift test --disable-sandbox --package-path Applet --scratch-path .build/applet
```

The signed application is `.build/Noodle Applet.app`. Its CLI is
`Contents/Helpers/noodlet`. Set `NOODLE_SIGNING_IDENTITY` to choose an identity and
`NOODLE_APPLET_CONFIGURATION=debug` for a debug build. The default is optimized, matching Computer. This is a local
development build; the script does not publish or notarize it.

Run `python3 Applet/scripts/smoke.py` after building to exercise the signed app
through its shipped CLI. It checks interaction, persistence, captures, compiler
diagnostics, native sandbox containment, and termination of blocked JavaScript.
Temporary creations are removed; captures are saved under `.build/applet/smoke`.

Building Noodle through `scripts/build-app.sh` also bundles the CLI and exposes the
companion in Settings. Noodle installs the managed Applet skill for every bot only
while the companion is installed. Startup, activation, and a five-second background
check refresh availability; removing Applet removes the managed skill, CLI link,
and agent guidance, and reinstalling restores them. Existing work is not restarted.
No per-bot assignment or global shell PATH installation is needed. The CLI links
use Noodle's bundled helper, which talks through Noodle to Applet's authenticated
local socket. Standalone callers can use the helper inside the Applet bundle.
The two applications remain separate packages and executables. Noodle does not
launch Applet until a bot requests it or the user opens the companion.

## Application updates

The application uses the same native window, sidebar, toolbar, Settings tabs,
and Sparkle update setup as Noodle Computer. **Applet → Check for Updates…**
and **Settings → Update** control updates; **Help → Noodle Applet Help** opens
the repository. Local builds disable update checks, matching Computer.

[Release preparation](RELEASING.md) uses the shared CI pipeline, signing secrets,
notarization, and signed feeds, with independent `applet-vX.Y.Z` releases and an
`applet-latest` channel. No public feed exists until the first release is published.

## Create a noodlet

```text
Hello.noodlet/
  noodlet.json
  index.html
  assets/
```

```json
{
  "version": 1,
  "title": "Hello",
  "runtime": "html",
  "entry": "index.html",
  "summary": "A small useful thing.",
  "symbol": "sparkles",
  "network": false
}
```

HTML can use local CSS, JavaScript, images, Canvas, and WebGL. Set `network` to
true for remote resources and native HTTP(S) requests; top-level navigation remains inside the package.
Packages are limited to 512 regular files and 20 MiB. Internal symlinks and path
traversal are rejected. The manifest is limited to 64 KiB.

Use **File → Open Noodlet…** or double-click a package in Finder to add and open
it. Agent CLI imports appear automatically in the library. No folder registration
is required. Right-click a creation and choose **Reveal Package** to see its files.
Menu bar access is off by default and can be enabled in General settings.
Opened external packages are remembered once, including aliases, and automatically
removed from the collection if the package is deleted.

Finder's Space preview renders HTML through the bundled Quick Look extension.
Swift previews use an optional package `preview.png` or the most recent captured
image, cached by package location. Quick Look has temporary data; open the noodlet
in Applet for persistent data, native execution, and full interaction.

## Window configuration

Both runtimes accept an optional `window` object in `noodlet.json`:

```json
"window": {
  "type": "floating",
  "background": "translucent",
  "titlebar": false,
  "width": 320, "height": 350,
  "minWidth": 260, "minHeight": 300,
  "maxWidth": 480, "maxHeight": 520,
  "resizable": true,
  "rememberFrame": true
}
```

`type` is `standard` (default), `floating` (above ordinary windows), or `preview`
(a non-activating floating panel with a compact close-only title bar).
`background` is `opaque` (default), `translucent` (a native macOS material), or
`transparent`. HTML must keep its `html` and `body` backgrounds transparent to
show that material. macOS WebKit's transparent page background currently requires
a guarded `_setDrawsBackground:` compatibility hook; an unsupported WebKit build
reports that limitation in the session log. `titlebar: false` hides the title and extends content into
the title bar while retaining native window controls. Keep content clear of them.

All dimensions are content points, from 120 to 4096. Minimums cannot exceed
maximums, and an initial size must fit the bounds. Resizing defaults on;
`resizable: false` locks user resizing. Remembering size and position defaults
off. `rememberFrame: true` restores them by canonical package location. Headless
runs and explicit CLI sizes ignore remembered frames; dimensions are still
clamped to the package's limits. The bundled Focus example uses these controls.

HTML can define additional native drag regions with CSS:

```css
header { --noodle-app-region: drag; user-select: none; }
header .interactive { --noodle-app-region: no-drag; }
```

Buttons, links, inputs, selects, and editable content are excluded automatically.
Dragging uses a real mouse-down from this noodlet's window; synthetic agent input
does not move the user's desktop windows. Hidden title bars also retain a native
30-point drag strip beside the window controls.

## Web requests

With `network: true`, ordinary `fetch()` and `noodle.fetch()` use native HTTP(S)
requests, so browser CORS does not block calls to APIs:

```js
const response = await fetch('https://example.com/api', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ message: 'Hello' }),
  signal: AbortSignal.timeout(10000)
});
if (!response.ok) throw new Error(`HTTP ${response.status}`);
const result = await response.json();
```

Responses support the standard text, JSON, Blob, and ArrayBuffer readers. Headers,
binary request bodies, redirects, and cancellation are supported. Requests and
responses are buffered with a 16 MiB limit, eight concurrent requests per noodlet,
and a 120-second overall timeout. Explicit API credentials are supported; browser
cookies and saved system credentials are not shared. Credentials are stripped on
cross-origin redirects. XMLHttpRequest, WebSockets, resource loading and embedded
frames retain WebKit's normal rules; local fetches continue through WebKit.
Network-disabled packages reject native requests before opening a connection.

## Agent workflow

Noodle bots read `.agents/skills/applet/SKILL.md` and run its `noodlet` symlink.
Standalone terminal use runs the helper inside the Applet bundle. Both return
JSON on stdout, including errors; failures exit with status 1.

```sh
noodlet open Hello.noodlet --mode headless
noodlet inspect --session SESSION_UUID
noodlet eval --session SESSION_UUID --text 'return document.title;'
noodlet click --session SESSION_UUID --target '#start'
noodlet screenshot --session SESSION_UUID --output preview.png
noodlet record start --session SESSION_UUID --duration 5
noodlet record stop --session SESSION_UUID --output demo.mp4
noodlet logs --session SESSION_UUID --follow --text-output
noodlet terminate --session SESSION_UUID
```

`open`, `build`, and `validate` transfer source files into the companion's private
library when the source is not already in an authorized library folder. Copies
are keyed by the bot identity and canonical source location. Reopening the same
source updates its copy and reconnects to an existing live instance. `restart`
rebuilds/reloads changed source and returns a new session ID. Changing location
creates an independent copy. Keep the returned ID for subsequent commands.

`headless` renders without a visible window and uses separate test data.
`background` uses normal data without showing a window. `foreground` and `show`
bring the noodlet forward. Offscreen execution still requires a logged-in macOS
desktop session; this is not a WindowServer-free server runtime. Input is delivered
to the noodlet's own view and does not move the system mouse or type into other apps.

Log output includes lifecycle events, compiler diagnostics, stdout/stderr, browser
console messages, uncaught errors, and rejected promises. Logs are JSON lines on
disk, with byte cursors for streaming. Session IDs remain usable for logs after
the companion restarts. Check status before retrying a timed-out mutation.

### Sharing without launching

```sh
noodlet validate Hello.noodlet
noodlet info --path Hello.noodlet
# Use the returned url; do not invent an ID.
messenger --send --conversation CONVERSATION_UUID --attach 'noodlet://RETURNED_UUID'
noodlet info --id 'noodlet://RETURNED_UUID'
```

Validation registers the source without running it; HTML needs no build step.
Responses include `noodletID`, `url`, `title`, `runtime`, and `path`. The persistent
noodlet ID is separate from a running `sessionID`. `list` also returns IDs and URLs.
Source updates and tracked moves retain the ID; independent copies get new IDs.
Missing packages resolve as unavailable, and restoring the package can restore
its link. IDs are stored in Applet's registry, not in authored manifests.

Messenger copies only a small `.webloc` bookmark into the conversation. Noodle
resolves its ID through the signed Applet connection to display a thumbnail.
Clicking the attachment opens the live creation in Noodle Applet, or brings its
existing window forward. Both HTML and Swift run with full interaction and saved
data; the click does not use Quick Look. Attaching the link alone does not launch
the creation. Capturing first gives the card a current image. Finder's preview
of the `.webloc` itself does not resolve the custom URL.

Conversation participants use `--id URL --conversation CONVERSATION_UUID` with
`info`, `open`, inspection, input, captures, or closing. The broker checks that
the link was sent in that conversation and that the caller is a participant.
It grants access to that specific creation, not another bot's workspace or source
replacement. Links refer to this Mac's registry and are not portable copies.

`present --session SESSION_UUID --conversation CONVERSATION_UUID` refreshes the
cached preview and sends the same live link. It sends a real message and needs
the user's authorization. Opening a `noodlet://UUID` URL outside Noodle opens the
registered creation in Applet without showing the library. Opening the application
directly, or choosing File → Open Library, shows the collection.

The signed integration fixture can be run with
`'.build/Noodle Local.app/Contents/MacOS/Noodle' --applet-link-test` after building
both apps. It creates temporary agents and a package, exercises the shipped CLI,
sharing, captures, sandbox bookmark handoff, opening the live creation, window
reuse, interaction, and saved data, then cleans up.
It never starts real agents or opens the user's repository.

Run `noodlet --help` for all commands. CLI help and the bot skill are generated
from the root project's `Sources/NoodleCore/MessengerDocumentation.swift`.

## Persistent data

```js
await noodle.storage.set('score', 42);
const score = await noodle.storage.get('score'); // null when absent
await noodle.data.writeText('notes/today.txt', 'Hello');
const text = await noodle.data.readText('notes/today.txt');
const selected = await noodle.files.openText(); // { name, text } or null
await noodle.files.saveText('result.txt', 'Hello');
```

The bridge scopes data paths to this noodlet and limits text files to 4 MiB.
Data lives outside source packages, so replacing source preserves saved work.
Each package also has its own WebKit website data store. File dialogs require a
visible noodlet window; no dialog is silently opened during background execution.

## Native Swift

Set `runtime` to `swift` and `entry` to a `.swift` file, then define a SwiftUI view:

```swift
import SwiftUI

struct Noodlet: View {
    var body: some View { Text("Hello from Swift").padding(40) }
}
```

The host supplies the application entry point; do not add `@main`. Swift sources
are combined in filename order into one script, typechecked, and evaluated in
the installed Apple Swift interpreter. They therefore share one file scope.
Compilation and execution occur in child processes. This avoids launching newly
quarantined executables while retaining native framework access.

Use SwiftUI, AppKit through `NSViewRepresentable`, SpriteKit, and installed Apple
SDKs. `NoodletContext.dataDirectory` and `.packageDirectory` expose file URLs;
`.isBackground` reports the initial launch mode. Xcode must be installed at
`/Applications/Xcode.app`, or Command Line Tools at their standard location.
The compiler and SDK are not bundled. HTML needs neither.

## Capture and containment

The host is signed with App Sandbox, outbound networking, user-selected file
read/write, app-scoped bookmarks, and one private Noodle Applet application group.
Sparkle adds the same two bundle-specific installer Mach service exceptions as
Computer; its signed installer replaces the application outside the sandbox.
The unused downloader service is removed. Verification checks the exact six-key
host entitlement set and each embedded updater component. The signed Quick Look
extension has only sandbox, outbound network, and the shared preview-cache group;
it has no file-write grants or native-code runner.
The group socket authenticates peer audit tokens and signing identities. Noodle
stamps bot identity before forwarding requests; bots cannot select another bot's
sessions or captures. CLI helpers run in the invoking harness's boundary and do
not receive the application group entitlement. Native Swift subprocesses inherit
the host sandbox; they cannot exceed it, but their per-noodlet data directories
are conventions rather than a security boundary between native creations.
The manifest's network switch applies to HTML only. Run trusted native code.

Web input is synthetic DOM input and cannot emulate trusted browser gestures.
JavaScript evaluation is available for HTML noodlets. Native input supports
clicks, drags, keys, and focused text controls; native scroll injection is not yet
implemented.
Snapshots capture WebKit content, ordinary native views, and SpriteKit scenes;
arbitrary Metal, video, and embedded web surfaces can need a specific renderer.
Recordings are silent H.264 MP4 at up to 12 fps, bounded to 60 seconds. They capture
only noodlet content and do not request Screen Recording or Accessibility access.
For hidden SpriteKit scenes, capture advances the scene's `update` callback.
