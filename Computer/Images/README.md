# Computer images

Noodle Computer uses two public ARM64 images:

| Image | Base | Purpose |
| --- | --- | --- |
| `ghcr.io/pdparchitect/noodle-computer-shell-image` | Alpine | Lightweight shell and network setup |
| `ghcr.io/pdparchitect/noodle-computer-desktop-image` | Ubuntu 24.04 | Browser, terminal, and file manager |

Dockerfiles pin official upstream image digests. Desktop is built entirely from
this repository; it never pulls a Launcher image. KasmVNC and Cortile downloads
are versioned and checksum-verified; apt/browser packages receive upstream
updates at build time, so the full build is not byte-for-byte reproducible.
See [desktop source provenance](desktop/NOTICE.md) for imported files and licences.
New computers fetch `:latest`; existing computers change only when the user chooses
**Update**, which preserves their writable files.

## Build and test

From the repository root, using Docker on ARM64 Linux:

```sh
docker build -f Computer/Images/shell/Dockerfile -t noodle-computer-shell-image:local Computer/Images
docker build -f Computer/Images/desktop/Dockerfile -t noodle-computer-desktop-image:local Computer/Images
docker run --rm --network none --entrypoint /bin/sh noodle-computer-shell-image:local /usr/local/lib/noodle-image-check shell
docker run --rm --network none --entrypoint /bin/sh noodle-computer-desktop-image:local /usr/local/lib/noodle-image-check desktop
docker run --rm -i --network none --entrypoint /bin/sh noodle-computer-desktop-image:local < Computer/Images/tests/desktop.sh
docker run --rm -i --user root --network none --entrypoint /bin/bash noodle-computer-desktop-image:local < Computer/Images/tests/startup.sh
python3 Computer/Images/tests/native-startup.py docker noodle-computer-desktop-image:local
python3 Computer/Images/tests/welcome.py docker noodle-computer-shell-image:local noodle-computer-desktop-image:local
python3 Computer/Images/tests/file-user.py docker noodle-computer-shell-image:local noodle-computer-desktop-image:local
docker run --rm -i --user root --network none --entrypoint /bin/bash noodle-computer-desktop-image:local < Computer/Images/tests/browser.sh
docker run --rm -i --network none --entrypoint /bin/sh noodle-computer-shell-image:local < Computer/Images/tests/user.sh
docker run --rm -i --network none --entrypoint /bin/sh noodle-computer-desktop-image:local < Computer/Images/tests/user.sh
```

On macOS, build with `container build --platform linux/arm64` and the same file,
tag, and context arguments. The welcome test also accepts `container`.
Noodle Computer owns authenticated desktop startup; running the image alone opens a shell.

## Automate the visible browser

Desktop opens Chromium with a persistent profile at
`/home/agent/.config/noodle-browser`. You can sign into websites in that window
and let an assigned agent automate the same tabs. The first launch copies the
previous desktop Chromium profile, leaving the original intact.

`puppeteer-core` is pinned in `desktop/browser/package-lock.json` and installed
at `/opt/noodle-browser`; it uses the system browser without downloading another
Chrome. Run a `.cjs` script **inside the guest**:

```js
const { connect } = require('/opt/noodle-browser');

(async () => {
  const browser = await connect();
  try {
    for (const page of await browser.pages()) {
      console.log(await page.title(), page.url());
    }
    // Select the intended tab by URL before interacting with it.
  } finally {
    await browser.disconnect(); // Leave the user's browser open.
  }
})().catch(error => { console.error(error); process.exitCode = 1; });
```

The helper attaches through `http://127.0.0.1:9222` and preserves the desktop's
viewport. It never launches a browser. If Browser was closed, reopen it from
the desktop or run `chromium` in a guest terminal. Root terminal launches use
the desktop account and profile too. Do not use `browser.close()`, headless
launches, or a new incognito context when continuing the user's signed-in work.

The debugging port listens only on guest loopback and is not published to the
host or LAN. Every agent assigned to the same computer can use its browser and
website sessions. Pause automation during user sign-in, avoid logging secrets,
and coordinate use of shared tabs. Website sessions may expire normally; this
does not enable Google Chrome account sync. Older computers need an image
**Update** after an image containing this feature is published. Shell and custom
images do not automatically gain these tools.

For dependency maintenance on macOS, use the `nodejs-apple-container` skill with
`desktop/browser` as the project. Its designation uses
`nodejs-noodle-desktop-browser` and the `nodejs-noodle-desktop-browser-modules`
named volume, with no published ports. Keep dependencies out of the host tree.

## Build your own desktop

The [example derivative](examples/desktop/Dockerfile) inherits the desktop and
adds a homepage, workspace seed, session notification, and appearance defaults:

```sh
docker build --build-arg DESKTOP_IMAGE=noodle-computer-desktop-image:local \
  -t my-desktop:local Computer/Images/examples/desktop
docker run --rm -i --user root --network none --entrypoint /bin/bash \
  my-desktop:local < Computer/Images/tests/startup.sh
```

Use `FROM ghcr.io/pdparchitect/noodle-computer-desktop-image@sha256:...` with a
released digest for a downstream release. Install tools and copy an `overlay/`
as root, then restore `USER agent`. Inherit `/init` and `desktop-prepare`.
No Launcher source checkout or special build orchestrator is needed.

To change the source build itself, pass `UBUNTU_IMAGE`, `NODE_IMAGE`,
`EXTRA_APT_PACKAGES`, or `DESKTOP_BRAND` as build arguments. The default OS is
Ubuntu Noble; substitutes must provide compatible apt packages and libraries.
Updating `KASMVNC_VERSION` or `CORTILE_VERSION` also requires the matching
`*_SHA256_ARM64` and `*_SHA256_AMD64` build arguments. The recipe supports both
architectures; published Noodle images and CI target ARM64.

### Configuration and overlays

Drop-ins in `/etc/desktop/conf.d/*.sh` are read in filename order, then
`/etc/desktop/config.sh` fills any remaining defaults. These are trusted system shell
files. Use `: "${VARIABLE:=default}"` in a drop-in to let environment variables
win; a plain assignment deliberately enforces the image's value. Derived Docker
`ENV` values and `container run -e`/`docker run -e` work without changing scripts.

| Setting | Default / effect |
| --- | --- |
| `DESKTOP_TITLE` | Noodle Computer; terminal title and hook environment |
| `DESKTOP_WALLPAPER` | `/usr/share/backgrounds/desktop-wallpaper.png` |
| `DESKTOP_BROWSER_URL` | `file:///opt/browser/index.html`; browser launches without arguments |
| `DESKTOP_BROWSER_AUTOSTART` | `1`; set `0` to leave Browser closed |
| `DESKTOP_TERMINAL_AUTOSTART` | `1`; set `0` to skip the initial terminal |
| `DESKTOP_PANEL_AUTOSTART` | `1`; set `0` to skip tint2 |
| `DESKTOP_COMPOSITOR_AUTOSTART` | `1`; set `0` to skip Picom |
| `DESKTOP_TILING_AUTOSTART` | `1`; starts Cortile with tiling initially disabled |
| `DESKTOP_GEOMETRY` | `1280x800`; initial size, resized by the client |
| `DESKTOP_FRAME_RATE` | `30`; KasmVNC frame-rate ceiling |
| `DESKTOP_PORT` / `DISPLAY` | `6901` / `:1`; configurable for standalone use, fixed by Noodle |
| `DESKTOP_STARTUP_DIR` | `/etc/desktop/startup.d`; executable hooks run as root in order before X starts; must return, failures abort startup |
| `DESKTOP_SESSION_DIR` | `/etc/desktop/session.d`; executables launched as `agent` inside X11/D-Bus after keyring setup; long-running programs may stay in foreground |

Replace these paths through an overlay to customize the desktop:

| Path | Controls |
| --- | --- |
| `/usr/local/share/desktop/workspace/` | Seeds copied into `/workspace` on startup; existing files, including dotfiles, are preserved |
| `/etc/xdg/openbox/{rc.xml,menu.xml}` | Keybindings and applications menu |
| `/etc/xdg/tint2/tint2rc` | Panel layout |
| `/etc/xdg/kitty/{kitty.conf,theme.conf}` | Terminal defaults and palette; existing user config is preserved |
| `/etc/xdg/picom.conf` | Window corners/compositing |
| `/etc/xdg/cortile/config.toml` | Initial tiling config; existing user config is preserved |
| `/usr/local/bin/desktop-welcome` | Initial terminal and Welcome menu action |
| `/usr/local/bin/desktop-harness` | Control-Shift-G action |
| `/usr/local/bin/desktop-panel-status` | Panel status text |
| `/etc/desktop/browser-preferences.json` | Preferences for new browser profiles |
| `/opt/browser/index.html` | Bundled browser homepage |

Run `kasm-patch "Your Brand"` while building a derivative to change the web
client title. `NOODLE_BANNER=0` disables the shell welcome; `NO_COLOR=1` disables
its colour. These settings are separate from the macOS app's appearance.

### Desktop startup contract (v1)

The image label `im.noodle.desktop.contract=1` identifies this contract:

1. Keep `agent` UID/GID 1000, `/home/agent`, writable `/workspace`, passwordless
   sudo, and the shared browser at `/opt/noodle-browser`.
2. As root, run `/usr/local/bin/desktop-prepare` with a fresh
   `NOODLE_DESKTOP_PASSWORD` (Noodle) or `DESKTOP_PASSWORD` (standalone).
   It emits only the base64 DER certificate on stdout, generates a new one-day
   certificate, and installs KasmVNC credentials. Missing credentials fail.
3. As root, run `/init`. It serves authenticated HTTPS on 6901, launches Xvnc and
   applications as `agent` on `:1`, and stops the display when terminated.
   It requires preparation and never enables unauthenticated access.

Session state is at `/run/desktop` (Xauthority and D-Bus address); logs are at
`/var/log/desktop`. The local browser debugging endpoint remains loopback-only
on 9222. There is no control bridge or service on 6902.

Noodle retains image environment defaults while fixing its account, display,
port and generated credentials. Add a derived image to the bundled
[container registry](../Sources/ComputerCore/Resources/container-registry.json)
with runtime type `desktop` to use the native pinned-certificate viewer.
The generic Custom Container web view does not implement this desktop contract.

For standalone use, run as root with `--entrypoint /usr/local/bin/desktop-start`
and `DESKTOP_PASSWORD_FILE` pointing at a mounted file containing 16–128 random
letters/digits. Publish the chosen HTTPS port to loopback only; log in as `agent`.
Running the image with no overrides still opens a non-root shell.

Ship the Computer app's v1 startup support before publishing this image: older
apps do not understand the new contract. The updated app retains a fallback for
existing saved images, so they keep working until the user chooses **Update**.

## Publish

Only publish when explicitly requested. Images have their own `VERSION` and
`CHANGELOG.md`, independent of both apps.

1. Choose a higher, unused version and move relevant Unreleased notes into a dated release section.
2. Commit and push to `main`; the version change requests publication.
3. Watch the [shared release workflow](../../docs/releases.md). It tests both images, creates `computer-images-vX.Y.Z`, and publishes the exact tested artifacts.
4. Verify both GHCR packages are **Public**, linked to this repository, and pullable anonymously as ARM64 images. Check versioned and `:latest` digests match.

CI uses `GITHUB_TOKEN`. Never create or move version tags manually, rebuild a
published version, or ship registry credentials in the app. Retry failed jobs in
the original workflow to reuse its tested artifacts. Images create no GitHub app
release; digests are recorded in the workflow summary and artifact.

Both public `:latest` images must exist before an app depending on them ships.
Check Shell startup and networking, Desktop's authenticated display, wallpaper,
and terminal when changing the image contract.

[Computer](../README.md)
