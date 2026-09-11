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
```

On macOS, build with `container build --platform linux/arm64` and the same file,
tag, and context arguments. The welcome test also accepts `container`.
Noodle Computer owns authenticated desktop startup; running the image alone opens a shell.

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
