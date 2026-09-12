# Keyboard shortcuts

Open **Noodle → Settings → Keybindings** to discover commands and change their shortcuts. Each row explains what the command does and shows its current binding.

| Command | Default | Where it works |
| --- | --- | --- |
| New Bot | ⌘N | Noodle, when a harness is available |
| New Group | ⇧⌘N | Noodle |
| Search Conversations | ⌘F | The current chat window |
| Record / Stop Voice Message | ⇧⌘D | The current chat, on macOS 26 or later |
| Add Annotation | ⇧⌘A | Selected text in an attachment preview; starts region selection for images |
| Annotate Region | ⇧⌘R | The current attachment preview |
| Save Annotation Comment | ⌘Return | The annotation popup or an unsent annotation's comment editor |

Click a binding, then press the new combination using Command (⌘) or Control (⌃). Escape cancels recording; Delete clears the binding. Right-click a binding to reset that command or clear it. **Restore Defaults** resets all commands. Conflicting assignments and common system/editing shortcuts are rejected with an explanation; the existing binding stays intact.

Bindings apply immediately to menus, native preview handlers and shortcut hints, and persist across launches. A cleared binding leaves its menu command or button available. Recording a shortcut consumes the keystroke so it does not execute the command. Capture ends when Settings loses keyboard focus, the control is removed, or you click elsewhere.

These are shortcuts within Noodle. Standard controls retain their native behavior: Return sends a chat message, Shift-Return inserts a line break, Escape cancels an annotation or closes an idle preview, and Space opens a focused attachment. Submitting an annotation makes its comment read-only regardless of the save shortcut.

## Validation

`swift test --disable-sandbox --filter KeyboardShortcutsTests` checks defaults, conflicts, reserved commands, disabled bindings, persistence and reset behavior. `Tests/attachment-annotations.sh --headless` also exercises native event normalization, shared menu/preview bindings, recorder save/cancel/clear/conflict handling, inactive-window passthrough and an offscreen render of the actual Settings view. It verifies that changing a binding updates the existing control without reopening the tab. No foreground input or app activation is used by the hidden checks.
