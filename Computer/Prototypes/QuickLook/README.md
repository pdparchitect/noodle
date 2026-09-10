# Quick Look interaction feasibility

This is an isolated feasibility test for the Computer provider wiring phase.
It is not built into Noodle or Noodle Computer and does not access either library.
No guest, network connection, command execution, bridge or registration is enabled.

Build with `zsh Computer/Prototypes/QuickLook/build.sh`. The script creates a new
temporary app, signed with an available Apple Development identity. Host and
extension grant only App Sandbox. The host uses the same SwiftUI
`.quickLookPreview` entry point as Noodle's existing attachments.

The custom document type and extension identifiers are isolated from production.
The extension presents an editable native NSTextView, not a terminal: keyboard
input must work at this basic level before connecting a real guest PTY.

## Observed on the development Mac, 2026-09-09

- The system Quick Look panel loads and renders the view-based preview extension.
- The editable text area is present in the accessibility tree.
- Clicking the text area via accessibility and at its visible coordinates does
  not give it keyboard focus; typing does not change its contents.
- Explicit `view.window?.makeFirstResponder(editor)` in `viewDidAppear` returns false.
- A subsequent direct key press is ignored by the text area.
- Space closes the Quick Look panel rather than inserting a space.
- The preview host regains focus after dismissal.

This proves rendering but **does not prove interactive terminal support** through
the existing Quick Look route. Do not ship a claim of equivalent mechanics or
replace the preview with a custom panel without resolving the user's requirement.
No private Quick Look APIs or event-injection workarounds were attempted.

Both probe bundles pass strict signature verification and link only Apple/system
libraries. Test extension registrations were removed and the test app was quit
after the test. Temporary build bundles remain reproducible diagnostic artifacts.

## Next decision

Either establish a supported interactive route through the actual Quick Look
panel, or obtain the user's approval for a Noodle-owned interactive preview that
preserves attachment opening/dismissal/focus conventions while routing text keys
to the focused terminal. The alternative is a true Quick Look snapshot with an
explicit Open Computer action; that would not meet the requested in-preview use.

Provider discovery, multi-agent assignment, CLI and live sessions remain pending.
