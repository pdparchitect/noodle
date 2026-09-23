# Noodle Hub

Noodle Hub runs bots on an always-on Mac so the people you pair with it can use them.
It lives in the menu bar and keeps its bots, harnesses and conversations apart from
Noodle's own.

## Develop

```sh
cd Hub
swift build
swift test
.build/debug/NoodleHub
```

The Hub appears in the menu bar and lists the harnesses it finds on this Mac.
