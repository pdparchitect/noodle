# Quick Look keyboard probe

This isolated prototype tested whether a Quick Look extension could accept terminal
keyboard input. On 2026-09-09, the view rendered but could not take keyboard focus;
Space dismissed the panel.

Noodle therefore uses its own interactive panel for Computer cards. Ordinary file
attachments still use Quick Look. See [the integration guide](../../Bridge/README.md).

To reproduce, run `zsh Computer/Prototypes/QuickLook/build.sh` from the repository
root. It creates a temporary app signed with an Apple Development identity and
uses an editable text view as the input probe. It does not open a guest or either
app's library.
