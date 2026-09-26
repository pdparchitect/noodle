import AppKit
import HubLink
import NoodleHubClient
import NoodleRuntimeSettings
import SwiftUI

/// A card in a Hub bot's conversation, opened live.
struct HubSurfaceTarget: Hashable {
    let conversationID: UUID
    let attachmentID: UUID
    let title: String
}

/// Live views open floating, in the same dark frame as previews, one panel per link. Escape
/// belongs to what is shown; the close button and ⌘W close the panel, which ends the view.
@MainActor final class HubSurfacePanels: NSObject, NSWindowDelegate {
    private var panels: [HubSurfaceTarget: NSPanel] = [:]

    func open(_ target: HubSurfaceTarget, store: NoodleStore) {
        if let panel = panels[target] { return panel.makeKeyAndOrderFront(nil) }
        let panel = HubSurfacePanel(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.collectionBehavior = [.fullScreenAuxiliary, .fullScreenDisallowsTiling]
        panel.minSize = NSSize(width: 480, height: 340)
        panel.title = target.title
        let content = NSHostingView(rootView: HubSurfaceWindow(target: target).environment(store).preferredColorScheme(.dark))
        content.sizingOptions = []
        panel.contentView = AnnotationPreviewFrame(content: content, filename: target.title, kindLabel: "Live",
            closeHint: "Close Live View (⌘W)", closeLabel: "Close Live View")
        let screen = NSApp.keyWindow?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
        var frame = panel.frame
        frame.size.width = min(frame.width, screen.width)
        frame.size.height = min(frame.height, screen.height)
        frame.origin = NSPoint(x: screen.midX - frame.width / 2, y: screen.midY - frame.height / 2)
        panel.setFrame(frame, display: false)
        panel.delegate = self
        panels[target] = panel
        panel.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSPanel,
              let target = panels.first(where: { $0.value === closing })?.key else { return }
        panels[target] = nil
        // Dropping the content ends the view, so the bot may go on.
        closing.contentView = nil
    }
}

private final class HubSurfacePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           event.charactersIgnoringModifiers == "w" { close(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Shows what a link points at on the Hub's Mac as live video, and passes on what the person
/// does over the same channel. Closing its panel ends it, and the bot may go on.
struct HubSurfaceWindow: View {
    @Environment(NoodleStore.self) private var store
    let target: HubSurfaceTarget
    @State private var feed = SurfaceFeed()
    @State private var channel: LinkChannel?
    @State private var showing = false
    @State private var failure: String?

    var body: some View {
        ZStack {
            SurfaceView(feed: feed) { control in channel?.send(LinkSurface.control(control)) }
            if !showing {
                if let failure { Text(failure).foregroundStyle(.secondary).padding() }
                else { ProgressView() }
            }
        }
        .background(.black)
        .task { await follow() }
        .onDisappear { channel?.cancel() }
    }

    private func follow() async {
        guard let mirror = store.hubMirror(forConversation: target.conversationID) else {
            failure = "Join that Noodle Hub again to open this."
            return
        }
        feed.onFirstPicture = { showing = true }
        do {
            let channel = try await mirror.openSurface(attachment: target.attachmentID, in: target.conversationID)
            self.channel = channel
            defer { channel.cancel() }
            for try await frame in channel.frames {
                switch LinkSurface.message(frame) {
                case .packets(let packets)?: feed.receive(packets)
                case .failed(let reason)?: failure = reason; showing = false
                default: break
                }
            }
            if !showing { failure = "The Hub could not show this." }
        } catch {
            failure = error.localizedDescription
        }
    }
}
