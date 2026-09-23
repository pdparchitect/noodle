# Noodle Hub

Noodle Hub runs bots on an always-on Mac so the people you pair with it can use them.
It lives in the menu bar and keeps its bots, harnesses and conversations apart from
Noodle's own.

## Develop

```sh
scripts/build-and-launch-hub.sh
```

This builds `Noodle Hub Dev` with Xcode and opens it. The Hub appears in the menu bar
with Settings and Quit. It needs an Apple Development signing identity, like Noodle.

To debug, generate the Xcode project and run it from Xcode:

```sh
cd Hub && tuist generate
```

The first build asks you to trust MLX's package plugin. `scripts/install-tuist.sh`
installs the pinned Tuist if you have none.

Run its tests with `cd Hub && swift test`.
