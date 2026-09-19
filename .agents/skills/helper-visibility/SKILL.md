---
name: helper-visibility
description: Dock and app-switcher policy for Noodle helpers. Use when creating or changing a helper app bundle, XPC or background executable, standalone development or test fixture, an Info.plist with LSUIElement or LSBackgroundOnly, or any NSApplication activation policy.
---

# Helper visibility

Helpers and standalone development/test fixtures must stay out of the Dock and
app switcher by default.

- Set `LSUIElement` for helper app bundles.
- Use AppKit's `.accessory` activation policy when they need windows.
- Use `LSBackgroundOnly` for background-only executable metadata.
- Do not promote helpers to `.regular`.

The main Noodle, Noodle Computer, and Noodle Applet apps retain their Dock entries.

## Verify

Check a running app without screenshots:

```sh
lsappinfo list | grep -A4 '"<App Name>" ASN'
```

`type="UIElement"` is hidden; `type="Foreground"` is in the Dock. Launch Services
resets a non-`LSUIElement` app to `.regular` on every open, reopen or URL request,
so check again after triggering one with `open -g`.
