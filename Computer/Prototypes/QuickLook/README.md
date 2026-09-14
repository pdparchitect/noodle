# Quick Look interaction investigation

Investigation stopped on 2026-09-14. The temporary app and prototype implementation
were removed during cleanup. The shipped preview shows saved content; opening a
reference selects the computer in the main Computer window.

The original 2026-09-09 probe rendered an editable native text view, but could not
give it keyboard focus; Space dismissed the panel. Its host also had a global Space
shortcut, so that result did not establish whether WebKit could accept input.

The second probe embedded a `WKWebView` in a Quick Look extension with local HTML:
a click counter, single-line and multiline inputs, and a focusable desktop keyboard
target. A native label reported actual input and focus. It compared the standard
Quick Look panel with a `QLPreviewView` embedded in a plain `NSWindow`, without a
global Space shortcut.

WebKit rendered, and an accessibility-triggered JavaScript click updated the
counter. Explicit DOM focus selected the input, but only the plain-window version
reported document and native window focus. Automated keystrokes did not update the
fields. The user also reported that normal mouse and keyboard interaction failed
in the plain-window comparison. Input remained unresolved when testing stopped;
the accessibility click did not establish normal input support. These results do
not support describing all Quick Look previews as noninteractive.

Closing the embedded preview crashed the test host because it manually closed a
`QLPreviewView` already configured with `shouldCloseWithWindow = true`. The duplicate
close was removed, but repeated open/close verification was not completed before
the investigation stopped.

Both targets used App Sandbox. The extension additionally needed the network-client
entitlement for WebKit's subprocess to launch, even for local HTML; without it,
WebKit reported `Application does not have permission to communicate with network
resources`. The page's content policy blocked network requests. No guest was
started, neither app's library was read, and no runtime connection or full
interactive desktop inside Quick Look was proven.
