# Noodle Applet

## Dev and production builds

The default build and Runbar's **Noodle Applet → Build & Launch Dev** use
Noodle Applet Dev. It connects only to Noodle Dev. Production Noodle connects
only to production Applet; neither falls back to the other when its companion is
missing. Their app containers, libraries, bookmarks, settings, saved runtime data,
WebKit stores, compiler caches, socket groups and preview caches are separate.

| Channel | App ID | Document | Link |
| --- | --- | --- | --- |
| Production | `com.pdparchitect.noodle.applet` | `.noodlet` | `noodlet://UUID` |
| Dev | `com.pdparchitect.noodle.applet.local` | `.noodlet-dev` | `noodlet-dev://UUID` |

Existing `.noodlet-local` packages and saved `noodlet-local://` links remain readable
only in Dev. New documents and links use Dev names. Internal `.local` IDs stay
stable to preserve data and permissions.

The Dev app and Quick Look extension register only the development document type;
they never claim the production type or URL scheme. Conversation links keep their
original environment. A foreign link shows an environment mismatch rather than
opening the other app or resolving its UUID in the wrong library.

Package contents use the same `noodlet.json` manifest and source formats. There is
no automatic migration or sharing. To transfer a creation, explicitly make a copy:

```sh
'.build/Noodle Applet Dev.app/Contents/Helpers/noodlet' convert \
  --path /path/Example.noodlet --output /path/Example.noodlet-dev
```

Reverse the extensions to export a production copy. Conversion never overwrites
an existing destination, creates a live link, or opens either app. Open or validate
the copy in its matching environment to register a new link. Existing production
files and links retain their current meaning. The examples below use production
names; use `.noodlet-dev` and `noodlet-dev://` when following them locally.

Explicit production packaging uses `NOODLE_APPLET_DATA_CONTAINER=production`;
public release scripts set it themselves. Production updates are disabled in Dev
builds. The guarded Runbar launcher always forces development and verifies the
resulting app identity before opening it.


A separate macOS companion for little tools, websites, experiments, and games.
Noodlets are ordinary folders ending in `.noodlet` (production) or `.noodlet-dev` (development), displayed as document packages
in Finder. The app provides an interactive viewer and a visual library; agents
write the source files using their usual tools.

## Build and run

Requires macOS 15+, Swift 6, and an Apple Development or Developer ID signing
identity. From the repository root:

```sh
scripts/build-applet.sh
open '.build/Noodle Applet Dev.app'
swift test --disable-sandbox --package-path Applet --scratch-path .build/applet
```

The default signed application is `.build/Noodle Applet Dev.app`. Its CLI is
`Contents/Helpers/noodlet`. Set `NOODLE_SIGNING_IDENTITY` to choose an identity and
`NOODLE_APPLET_CONFIGURATION=debug` for a debug build. The default is optimized, matching Computer. This is a local
development build; the script does not publish or notarize it.

Run `python3 Applet/scripts/smoke.py` after building to exercise the signed app
through its shipped CLI. It checks interaction, persistence, captures, compiler
diagnostics, native sandbox containment, and termination of blocked JavaScript.
Temporary creations are removed; captures are saved under `.build/applet/smoke`.

Run `'.build/Noodle Applet Dev.app/Contents/MacOS/NoodleApplet' --rendering-test` for
an isolated signed CLI fixture covering historical session selection, hidden
visibility, synthetic frame stepping, Canvas/WebGL capture pixels, and test-data
isolation. It uses its own runtime and socket without touching existing sessions.

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
the repository. Development builds disable update checks, matching Computer.

[Release preparation](RELEASING.md) uses the shared CI pipeline, signing secrets,
notarization, and signed feeds, with independent `applet-vX.Y.Z` releases and an
[`applet-latest` download channel](https://github.com/pdparchitect/noodle/releases/tag/applet-latest).

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

## Secrets

Keep API keys and tokens out of source, storage and data files:

```js
await noodle.secrets.set("openai", key)      // HTML
const key = await noodle.secrets.get("openai") // null when missing
```

```swift
try await NoodletContext.secrets.set("openai", key)   // Swift
let key = try await NoodletContext.secrets.get("openai")
```

`delete(name)` and `names()` complete the API. Applet keeps each noodlet's secrets
in its own login Keychain item, up to 64 values of 16 KiB, with separate values for
headless test runs. A noodlet can only ever reach its own: HTML through the bridge,
and native code because its confinement cannot read the Keychain at all.
**Settings → Secrets** lists names, never values, and removes them.
**Settings → Storage** shows each noodlet's saved data and removes it, including an
HTML noodlet's WebKit store.

## Permissions

Declare the protected resources a noodlet uses in `noodlet.json`:

```json
"permissions": ["microphone", "camera", "speech-recognition", "screen-capture"]
```

Applet asks once per noodlet before it starts, then macOS asks for Noodle Applet
as a whole. Declining fails `open` with `permission-denied`. HTML noodlets get
`getUserMedia` and `MediaRecorder` for the microphone and camera, and `getDisplayMedia`
for the screen, only when declared. macOS still shows its own screen picker. WebKit
has no public delegate for `getDisplayMedia`, so this uses a guarded private one; an
unsupported WebKit build reports that in the session log. A new screen recording
grant applies after Applet restarts.
`info`, `status` and `open` report each declared permission as `granted`, `denied`
or `not-requested`. **Settings → Permissions** lists what each noodlet was allowed
and removes it, so the noodlet asks again.
Native noodlets run in a child process that inherits Applet's grants, so the
declaration is the user's consent, not a boundary between native noodlets.

## Window dragging

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
Add `--session RETURNED_UUID` alongside the shared ID and conversation to target
the exact session from `open`, including headless sessions. The session must belong
to that package. A session UUID alone does not grant shared access. Without it,
package lookup selects an active session first, otherwise the newest historical
session. `list` shows only the caller’s own packages.
It grants access to that specific creation, not another bot's workspace or source
replacement. Links refer to this Mac's registry and are not portable copies.

`present --session SESSION_UUID --conversation CONVERSATION_UUID` refreshes the
cached preview and sends the same live link. It sends a real message and needs
the user's authorization. Opening a `noodlet://UUID` URL outside Noodle opens the
registered creation in Applet without showing the library. Opening the application
directly, or choosing File → Open Library, shows the collection.

The signed integration fixture can be run with
`'.build/Noodle Dev.app/Contents/MacOS/Noodle' --applet-link-test` after building
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

Swift macros such as `@State`, `@Observable`, `@Entry` and `#Preview` expand
through the installed toolchain's plugins. SwiftUI's macros ship only with Xcode,
so with Command Line Tools alone use `@StateObject` and `@Published` instead.
Availability checks, `.task` and other back-deployed APIs work in the interpreter.

## Capture and containment

The host is signed with App Sandbox, outbound networking, audio input, camera, user-selected file
read/write, app-scoped bookmarks, and one private Noodle Applet application group.
Sparkle adds the same two bundle-specific installer Mach service exceptions as
Computer; its signed installer replaces the application outside the sandbox.
The unused downloader service is removed. Verification checks the exact nine-key
host entitlement set and each embedded updater component. The signed Quick Look
extension has only sandbox, outbound network, and the shared preview-cache group;
it has no file-write grants or native-code runner.
The group socket authenticates peer audit tokens and signing identities. Noodle
stamps bot identity before forwarding requests; bots cannot select another bot's
sessions or captures. CLI helpers run in the invoking harness's boundary and do
not receive the application group entitlement. Native Swift code is treated as
untrusted. App Sandbox refuses a nested sandbox, so `NoodletHost.xpc` runs outside
it, accepts only the Applet it ships in, starts nothing but the installed Apple
compiler, and applies a deny-by-default profile to every compile and run. A native
noodlet reads the system, the toolchain, its build and the module cache, and
writes only its data directory and a private home directory. The user's files,
other noodlets, Applet's storage, its security-scoped bookmarks and the Keychain
are out of reach. The shared module cache is filled before noodlet code runs and
is read-only afterwards. Files enter or leave only through Applet's own dialogs:
`NoodletContext.files.open()` copies the user's choice into the data directory and
`files.save` copies a data file out. Outbound network, and the devices a granted
permission names, remain available. The manifest's network switch applies to HTML only.

Web input is synthetic DOM input and cannot emulate trusted browser gestures.
JavaScript evaluation is available for HTML noodlets. Native input supports
clicks, drags, keys, and focused text controls; native scroll injection is not yet
implemented.
Snapshots capture WebKit content, ordinary native views, and SpriteKit scenes;
arbitrary Metal, video, and embedded web surfaces can need a specific renderer.
Recordings are silent H.264 MP4 at 30 fps, bounded to 60 seconds. A noodlet that
cannot be captured that fast holds each frame for a whole number of them, so playback
stays even. They capture only noodlet content and do not request Screen Recording or
Accessibility access.
For hidden SpriteKit scenes, capture advances the scene's `update` callback.

### Hidden HTML animation checks

Background and headless pages may remain hidden and WebKit may suspend
`requestAnimationFrame`; games can also intentionally pause on visibility loss.
A running session or successful PNG does not prove that a Canvas/WebGL scene has
rendered. Responses report `mode`, `dataScope`, `testClock`, `viewAvailable`, and
page-reported `rendering` observations: document readiness, effective/native
visibility, synthetic timing, observed RAF frame count and its last timestamp.
Compare counts across commands and inspect captured pixels. Status uses the latest
reported observations so blocked page JavaScript does not block status itself.

For synthetic main-page animation tests, opt in explicitly:

```sh
noodlet open --path Game.noodlet --mode headless --test-clock
noodlet step --session RETURNED_UUID --frames 60
noodlet screenshot --session RETURNED_UUID --output frame.png
noodlet close --session RETURNED_UUID
```

`step` advances RAF and `performance.now()` at 60 Hz, accepts 1–600 frames, and
defaults to one frame. The page sees visible document state; diagnostics preserve
the native visibility too. Each capture records the current frame without stepping.
Date, timers, CSS animations, workers and media retain native timing, so this is
not a full virtual browser clock or real-time gameplay/performance evidence.
The clock is limited to HTML with headless test storage. Close the existing session
before switching between normal/test storage or clocks. A headless restart retains
the clock. Keep normal hidden-window pause behavior in shipping games.


The read-only identity and socket regression can be run with
`python3 Applet/scripts/test-connection-isolation.py`. It uses temporary signed
headless peers, verifies matching broker/CLI identities and both directions of
cross-environment rejection, and never opens a real app or library. Unit tests
cover link preservation, discovery, package conversion, and rejected foreign
imports. `scripts/verify-applet-release.sh` checks the actual signed app and preview
extension for exact channel-specific file, URL and group declarations.
