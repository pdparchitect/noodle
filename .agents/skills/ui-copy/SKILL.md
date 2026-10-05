---
name: ui-copy
description: Rules for user-visible text and controls in the Noodle apps. Use whenever adding or changing a label, title, button, menu item, link, toggle, status or error message, hint, placeholder, footer, shortcut legend, tooltip or any other visible string in a SwiftUI, AppKit or web view, especially when deciding on a trailing ellipsis or where a row's actions go.
---

# UI copy

Keep visible copy focused on functional labels and necessary status or error
messages.

Do not add persistent instructional hints, shortcut legends, or explanatory
footer text unless explicitly requested.

Put optional guidance in tooltips or documentation.

Annotating is by keyboard shortcut only. Never add an Annotate button or link
to any window, panel, header or footer; the Annotate menu commands stay.

## Ellipsis

End a label with `…` (the single character, never three dots) only when the
command needs more input before it can run: a name, a choice, a picker, a sheet
or window that has to be filled in.

- `Rename…`, `Pair…`, `Edit…`, `Settings…`: yes, they ask for more.
- `Check for Updates`: no, it just checks; any choices come after.
- `New Bot`, `New Container`: no, as in New Window or New Message, even when
  the new item opens a form.
- `Remove`, `Delete Plan`, `Quit`: no, even though they show an "Are you sure?"
  alert. A confirmation is not more input.
- `Invite`: no, its sheet only shows a code and link to share.
- Links and buttons that open System Settings or a web page: no.
- A toggle in a menu is a checkmark item, never an ellipsis.

## Row actions

- Keep a row to its main controls; move secondary actions and per-item
  switches into its `…` actions menu, with switches as checkmark items above a
  divider and the destructive action last; separate unrelated settings, such as a submenu and a switch, with a divider too.
- Buttons inside list rows use `.buttonStyle(.link)`, as in System Settings.
