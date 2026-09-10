# Noodle-owned base images

The Dockerfiles, overlays and publishing workflow live in this repository.
These are thin derivatives, not forks of the complete Launcher/Ghost stack:

- `ghcr.io/pdparchitect/noodle-shell`: pinned Alpine, preserving the tiny shell/network-bootstrap substrate.
- `ghcr.io/pdparchitect/noodle-desktop`: the currently tested Launcher desktop digest, plus a lighter cream/cobalt wallpaper and terminal palette.

Both target `linux/arm64` for Noodle Computer. Upstream digests are literal in the
Dockerfiles so an upstream tag change cannot silently change a rebuild. Software
and licences inherited from each upstream image remain applicable; our overlay
does not replace those components or add Ghost's agent runtimes.

## Build and check

Run from the repository root, using Docker on ARM64 Linux:

```sh
docker build -f Computer/Images/shell/Dockerfile -t noodle-shell:local Computer/Images
docker build -f Computer/Images/desktop/Dockerfile -t noodle-desktop:local Computer/Images
docker run --rm --network none --entrypoint /bin/sh noodle-shell:local /usr/local/lib/noodle-image-check shell
docker run --rm --network none --entrypoint /bin/sh noodle-desktop:local /usr/local/lib/noodle-image-check desktop
docker run --rm -i --network none --entrypoint /bin/sh noodle-desktop:local < Computer/Images/tests/desktop.sh
```

On macOS, use `container build --platform linux/arm64` with the same `-f`, `-t`
and context. These images default to a shell; the desktop does **not** start an
unauthenticated VNC server on `container run`. Noodle owns authenticated desktop
startup, and the inherited unauthenticated desktop bridge is disabled.
The rendering test starts a temporary loopback-only X server and checks actual
wallpaper pixels. Test scripts are not included in either production image.

## Wallpaper and later customisations

The source wallpaper is `desktop/overlay/usr/share/backgrounds/desktop-wallpaper.svg`.
It is an editable vector asset with a bright sky, cream sun and blue ribbons.
Replace this file to change new desktops' default without editing Launcher.
The base re-applies it when the remote screen resizes. Other formats supported by
`feh` can be used by changing `DESKTOP_WALLPAPER` in the Dockerfile.
The Linux desktop terminal palette lives in `desktop/overlay/etc/xdg/kitty/theme.conf`.
This is separate from the wallpaper and native-terminal settings in the macOS app.

No extra agent harnesses, credentials, host mounts or services are included.
Further product files can be layered into `desktop/overlay/` later.

## Publish (explicit approval required)

Image releases are independent of `Computer/VERSION` and Noodle's `VERSION`.
Pull requests and manual workflow runs build/test only. To publish, choose an
unused image version in this directory's `VERSION`, update the Computer changelog,
commit, then push a new `computer-images-vX.Y.Z` tag matching that version.
Never move/reuse an image tag; use a new version for a correction. Both images
must pass build and contract checks before either is pushed. No moving `latest`
tag or application release is created. The workflow attaches the resulting
immutable digests as an Actions artifact and writes them to its summary.

GitHub initially creates packages as **private**, even in a public repository.
After first publication, set both packages to **Public**, confirm they are linked
to `pdparchitect/noodle`, then verify anonymous ARM64 pulls. Do not ship registry
credentials in Noodle. The workflow uses the repository's short-lived
`GITHUB_TOKEN`, not a new personal access token.

## App promotion is a separate, tested change

The app still points at its existing tested upstream images until these images
are published and verified. Do not substitute nonexistent tags now. Promotion
must pin the published digests, preserve recognition of legacy desktop/shell
references in `Computer.swift`, and keep the Alpine network helper working.
Test creating/starting both presets and the desktop's authenticated display,
wallpaper and terminal before committing those new defaults.

Existing computers retain their writable root filesystems. Publishing a new
image changes neither their disks nor their wallpapers, and no destructive
rebuild/migration is automatic.
