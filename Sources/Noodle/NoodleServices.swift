import AppKit
import SwiftUI
import NoodleCore
import NoodleSharing

@MainActor
final class NoodleServices: NSObject, NSWindowDelegate {
    private var panels: [NSWindow: ShareComposerModel] = [:]

    @objc func sendToAgent(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        do {
            let inbox = try SharedInbox.configured()
            NoodleStore.active?.publishShareDestinations()
            var inputs: [ShareInput] = []
            let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
            if !files.isEmpty {
                inputs = files.map(ShareInput.file)
            } else if let text = pasteboard.string(forType: .string), !text.isEmpty {
                inputs = [.text(text)]
            } else if let url = pasteboard.string(forType: .URL), !url.isEmpty {
                inputs = [.text(url)]
            }
            guard !inputs.isEmpty else { throw SharedInboxError.emptyContent }
            let model = ShareComposerModel(inbox: inbox)
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = userData == "ask" ? "Ask Agent" : "Send to Agent"
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.contentView = NSHostingView(rootView: ShareComposer(model: model, send: { [weak panel] in
                do {
                    try model.send()
                    panel?.close()
                    Task { await NoodleStore.active?.processSharedInbox() }
                } catch { model.error = error.localizedDescription }
            }, cancel: { [weak panel] in panel?.close() }))
            panels[panel] = model
            model.load(inputs)
            panel.center()
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } catch let failure {
            error.pointee = failure.localizedDescription as NSString
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        panels.removeValue(forKey: window)?.cancel()
    }
}
