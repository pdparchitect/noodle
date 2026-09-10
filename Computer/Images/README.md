# Noodle-owned base images

The Dockerfiles, overlays and publishing workflow live in this repository.
These are thin derivatives, not forks of the complete Launcher/Ghost stack:

- `ghcr.io/pdparchitect/noodle-computer-shell-image`: pinned Alpine, preserving the tiny shell/network-bootstrap substrate.
- `ghcr.io/pdparchitect/noodle-computer-desktop-image`: the currently tested Launcher desktop digest, plus a textured landscape wallpaper in cream, teal and orange, black terminal and window borders, and rounded windows and top panel.

Both target `linux/arm64` for Noodle Computer. Upstream digests are literal in the
Dockerfiles so an upstream tag change cannot silently change a rebuild. Software
and licences inherited from each upstream image remain applicable; our overlay
does not replace those components or add Ghost's agent runtimes.

## Build and check

Run from the repository root, using Docker on ARM64 Linux:

```sh
docker build -f Computer/Images/shell/Dockerfile -t noodle-computer-shell-image:local Computer/Images
docker build -f Computer/Images/desktop/Dockerfile -t noodle-computer-desktop-image:local Computer/Images
docker run --rm --network none --entrypoint /bin/sh noodle-computer-shell-image:local /usr/local/lib/noodle-image-check shell
docker run --rm --network none --entrypoint /bin/sh noodle-computer-desktop-image:local /usr/local/lib/noodle-image-check desktop
docker run --rm -i --network none --entrypoint /bin/sh noodle-computer-desktop-image:local < Computer/Images/tests/desktop.sh
```

On macOS, use `container build --platform linux/arm64` with the same `-f`, `-t`
and context. These images default to a shell; the desktop does **not** start an
unauthenticated VNC server on `container run`. Noodle owns authenticated desktop
startup, and the inherited unauthenticated desktop bridge is disabled.
The rendering test starts a temporary loopback-only X server and checks actual
wallpaper pixels. Test scripts are not included in either production image.

## Wallpaper and later customisations

Interactive terminals share the Noodle ASCII welcome from `shared/noodle-welcome`.
The POSIX `ENV` hook covers shell-mode launches and native/provider PTYs; profile
and Bash hooks cover login shells and the desktop terminal. The logo appears once
per shell, never clears scrollback, and stays out of redirected or non-interactive
output. `NO_COLOR=1` disables colour; `NOODLE_BANNER=0` disables the welcome.
Run `python3 Computer/Images/tests/welcome.py container noodle-computer-shell-image:local noodle-computer-desktop-image:local`
to verify actual PTY startup in both local images (use `docker` on Linux).

The source wallpaper is `desktop/overlay/usr/share/backgrounds/desktop-wallpaper.png`.
It is a 1672 × 941 landscape with a cream sky, orange sun, teal hills and lake,
and warm foreground dunes, finished with a fine paper texture.
Replace this file to change new desktops' default without editing Launcher.
The base re-applies it when the remote screen resizes. Other formats supported by
`feh` can be used by changing `DESKTOP_WALLPAPER` in the Dockerfile.
The Linux desktop terminal palette lives in `desktop/overlay/etc/xdg/kitty/theme.conf`.
This is separate from the wallpaper and native-terminal settings in the macOS app.
Picom uses `desktop/overlay/etc/xdg/picom.conf` for 12-pixel window corners,
started through the base's desktop session hook. Its XRender backend needs no
GPU; shadows and animations are disabled. Maximized and fullscreen windows keep
square corners, and tint2 retains its own panel shape.

No extra agent harnesses, credentials, host mounts or services are included.
Further product files can be layered into `desktop/overlay/` later.

## Publish (explicit approval required)

Image releases are independent of `Computer/VERSION` and Noodle's `VERSION`.
Choose an unused version in this directory's `VERSION`, move the relevant notes
into a dated section in this directory's `CHANGELOG.md`, commit, and push to
`main`. That version change requests publication. The shared release workflow
reads the file and automatically derives `computer-images-vX.Y.Z`; never create,
move or reuse an image tag manually.

PRs build/test without publishing. On `main`, both ARM64 images must pass build,
contract, welcome and real desktop rendering checks. All other products selected
by version changes in the same push must also finish their checks and packaging
before any tag is minted. The workflow saves and later publishes the exact tested
images, then promotes both `:latest` tags and verifies anonymous access, image
versions and matching digests. It never rebuilds between checking and publishing.
The whole release pipeline is serialized so channel promotions cannot interleave.
No GitHub application release is created for images. Immutable image digests are
attached as an Actions artifact and written to the workflow summary.

Unchanged versions skip publishing. Re-run failed jobs in the original workflow
to reuse its tested image artifact; retries only accept an existing version tag
with the same image config digest. See the [shared release pipeline](../../docs/releases.md).

After first publication, check that both packages are **Public** (change their
visibility if needed), confirm they are linked to `pdparchitect/noodle`, then
verify anonymous ARM64 pulls. Do not infer package visibility from repository
visibility. Do not ship registry
credentials in Noodle. The workflow uses the repository's short-lived
`GITHUB_TOKEN`, not a new personal access token.

## New computers use latest

The app pulls `noodle-computer-shell-image:latest` and
`noodle-computer-desktop-image:latest` for new computers, checking the registry
even when the tag is cached locally. The Shell image used for network setup is
refreshed too. A failed pull fails creation instead of silently using an older image.
Publishing an image fix therefore does not require an app release. Custom image
references are also checked against the registry on creation and explicit updates.

Both public `:latest` tags must exist before shipping the app change that uses them.
Future image releases must keep the Alpine network helper and desktop startup
contract working. Test creating/starting both presets and the desktop's
authenticated display, wallpaper and terminal before publishing.

Existing computers change only when the user chooses Update. Updates replace the
read-only base while preserving the writable overlay; publishing an image never
automatically replaces a running computer or its files.
