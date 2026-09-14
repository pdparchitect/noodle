# Desktop source provenance

The desktop is built and maintained here from Ubuntu and official Node images.
No Launcher image, repository checkout, service, or build context is required.

The following files were imported and adapted from
[pdparchitect/launcher](https://github.com/pdparchitect/launcher/tree/c87522dbd8d49567267097596f763527d69d3741/images/bases/desktop)
at commit `c87522dbd8d49567267097596f763527d69d3741` (verified against remote HEAD):

- `openbox`, `gtk/Desktop`, `tint2`, `cortile`, `kasm`, and `browser` supply the
  window manager, theme, panel, tiling, web client assets, and browser start page.
- `gtk/generate-resource-overlay.py` generates matching GTK window controls.
- `shell/chromium`, `desktop-keyring`, `session-bus.sh`, `bashrc`,
  `desktop-panel-status`, `desktop-welcome`, and `desktop-harness` supply browser
  rendering defaults, keyring/session integration, and replaceable desktop helpers.
- The Ubuntu/desktop package selection and Openbox autostart were adapted from
  that repository. The authentication supervisor and configuration contract are
  maintained here; Launcher's bridge, runtime layering, fixed-mount root fallback,
  unauthenticated startup, and product-specific integrations are not imported.

The imported Openbox theme retains Dino Duratović's copyright and GPL-3.0-or-later
notice in `overlay/usr/share/themes/Desktop/openbox-3/themerc`. The GPL text is
available in the built image at `/usr/share/common-licenses/GPL-3`. Launcher has no
repository-wide LICENSE file at this revision; this notice records origin and
makes no additional licence grant. Preserve the original file notices when
redistributing derived images. Installed Ubuntu, Node, KasmVNC, Chromium/Chrome,
Cortile, and other packages retain their own licences and notices.
