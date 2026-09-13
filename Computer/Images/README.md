# Computer images

Noodle Computer uses two public ARM64 images:

| Image | Base | Purpose |
| --- | --- | --- |
| `ghcr.io/pdparchitect/noodle-computer-shell-image` | Alpine | Lightweight shell and network setup |
| `ghcr.io/pdparchitect/noodle-computer-desktop-image` | Launcher desktop | Browser, terminal, and file manager |

Dockerfiles pin upstream digests. Upstream software and licences still apply.
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

## Customize

| File | Controls |
| --- | --- |
| `desktop/overlay/usr/share/backgrounds/desktop-wallpaper.png` | Desktop wallpaper |
| `desktop/overlay/etc/xdg/kitty/theme.conf` | Linux terminal colours |
| `desktop/overlay/etc/xdg/picom.conf` | Window corners |
| `shared/noodle-welcome` | Interactive shell welcome |

`NOODLE_BANNER=0` disables the welcome; `NO_COLOR=1` disables its colour.
These settings are separate from the macOS app's appearance.

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
