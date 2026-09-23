# Noodle Hub

Noodle Hub runs bots on an always-on Mac so the people you pair with it can use them.
It lives in the menu bar and keeps its bots, harnesses and conversations apart from
Noodle's own.

## Develop

```sh
scripts/build-and-launch-hub.sh
```

This builds, signs and verifies `Noodle Hub Dev` in `.build`, then opens it. The Hub
appears in the menu bar with Settings and Quit. It needs an
Apple Development or Developer ID signing identity, like Noodle.

Run its tests with `cd Hub && swift test`.
