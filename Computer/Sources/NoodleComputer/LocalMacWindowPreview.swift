import AppKit
import LocalMacCore
import SwiftUI

struct LocalMacWindowPreview {
    let id = UUID()
    let window: LocalMacWindow
    var image: NSImage?
    var geometry: LocalMacWindowFrame?
    var error: String?
}

struct LocalMacFocusWindowButton: View {
    @ObservedObject var runtime: LocalMacComputer
    var enabled: Bool
    var all = false
    var body: some View {
        Button {
            guard enabled else { return }
            Task {
                if all { await runtime.openAllWindowPreviews() }
                else { await runtime.openWindowPreview() }
            }
        } label: {
            Label(all ? "Open All Windows" : "Focus Window", systemImage: all ? "rectangle.on.rectangle.angled" : "macwindow.on.rectangle")
        }
        .disabled(!enabled || !runtime.isConnected || runtime.status?.canControl != true ||
                  runtime.status?.displayID == nil || (all ? runtime.openingAllWindows : runtime.status?.focusedWindow == nil))
        .help(all ? "Open All Windows" : runtime.status?.focusedWindow.map { "Focus Window: \($0.label)" } ?? "Focus Window")
    }
}

private struct LocalMacWindowPreviewContent: View {
    @ObservedObject var runtime: LocalMacComputer
    let id: UUID
    var body: some View {
        let preview = runtime.windowPreviews[id]
        LocalMacSurface(runtime: runtime, active: preview?.geometry != nil, previewID: id)
            .background(.black)
            .overlay {
                if let error = preview?.error {
                    Text(error).multilineTextAlignment(.center).padding(24)
                } else if preview?.image == nil {
                    ProgressView("Opening window…").allowsHitTesting(false)
                }
            }
    }
}

enum LocalMacWindowLayout {
    /// Frame rectangles (including title bars), ordered left to right, top to bottom.
    static func frames(sizes: [CGSize], in visibleFrame: CGRect) -> [CGRect] {
        guard !sizes.isEmpty else { return [] }
        let area = visibleFrame.insetBy(dx: 12, dy: 12), gap: CGFloat = 12
        var best: [CGRect] = [], bestScale: CGFloat = 0, bestShape: CGFloat = .infinity
        // Pack preferred sizes without enlarging them. Try each row/column
        // arrangement and shrink only if none fits at the individual pop-out size.
        for columns in 1...sizes.count {
            let rows = (sizes.count + columns - 1) / columns
            var widths = [CGFloat](repeating: 0, count: columns)
            var heights = [CGFloat](repeating: 0, count: rows)
            for (index, size) in sizes.enumerated() {
                widths[index % columns] = max(widths[index % columns], size.width)
                heights[index / columns] = max(heights[index / columns], size.height)
            }
            let horizontalGap = gap * CGFloat(columns - 1), verticalGap = gap * CGFloat(rows - 1)
            let scale = min(1, (area.width - horizontalGap) / widths.reduce(0, +),
                            (area.height - verticalGap) / heights.reduce(0, +))
            guard scale > 0 else { continue }
            let width = widths.reduce(0, +) * scale + horizontalGap
            let height = heights.reduce(0, +) * scale + verticalGap
            let shape = abs(log((width / height) / (area.width / area.height)))
            guard scale > bestScale || (scale == bestScale && shape < bestShape) else { continue }
            bestScale = scale; bestShape = shape
            best = sizes.enumerated().map { index, size in
                let row = index / columns, column = index % columns
                return CGRect(x: area.midX - width / 2 + widths.prefix(column).reduce(0, +) * scale + CGFloat(column) * gap,
                              y: area.midY + height / 2 - heights.prefix(row).reduce(0, +) * scale - CGFloat(row) * gap - size.height * scale,
                              width: size.width * scale, height: size.height * scale)
            }
        }
        return best
    }
}

/// Owned by the connection, not the currently selected desktop view. These are
/// ordinary independent windows, so changing computers/files/terminals keeps them.
@MainActor final class LocalMacWindowPreviewPresenter: NSObject, NSWindowDelegate {
    private weak var runtime: LocalMacComputer?
    private(set) var windows: [UUID: NSWindow] = [:]
    private var order: [UUID] = []
    private var receivedFrames: Set<UUID> = []
    private var automaticFrames: [UUID: CGRect] = [:]
    init(runtime: LocalMacComputer) { self.runtime = runtime }

    func show(_ id: UUID, bringToFront: Bool = true) {
        guard let runtime, let preview = runtime.windowPreviews[id] else { return }
        if windows[id] == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = preview.window.label
            window.minSize = NSSize(width: 320, height: 220)
            window.contentView = NSHostingView(rootView: LocalMacWindowPreviewContent(runtime: runtime, id: id))
            window.delegate = self
            windows[id] = window
            order.append(id)
            let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
            window.setFrame(CGRect(x: screen.midX - min(window.frame.width, screen.width * 0.8) / 2,
                                   y: screen.midY - min(window.frame.height, screen.height * 0.8) / 2,
                                   width: min(window.frame.width, screen.width * 0.8),
                                   height: min(window.frame.height, screen.height * 0.8)), display: false)
            automaticFrames[id] = window.frame
            window.orderFront(nil)
            arrange()
        }
        sync(id)
        if bringToFront, let window = windows[id] {
            if window.isMiniaturized { window.deminiaturize(nil); arrange() }
            window.makeKeyAndOrderFront(nil)
        }
    }
    func sync(_ id: UUID) {
        guard runtime?.windowPreviews[id]?.geometry != nil, let window = windows[id],
              receivedFrames.insert(id).inserted else { return }
        // Replace provisional sizes as first frames arrive, without undoing a
        // user's move/resize or putting the newly sized window over its siblings.
        if windows.allSatisfy({ automaticFrames[$0.key] == $0.value.frame }) {
            arrange()
        }
        if let surface = findSurface(window.contentView) { window.makeFirstResponder(surface) }
    }
    private func preferredSize(_ id: UUID, window: NSWindow, screen: CGRect) -> CGSize {
        let bounds = runtime?.windowPreviews[id]?.geometry?.bounds ?? CGRect(x: 0, y: 0, width: 900, height: 600)
        let width = max(480, bounds.width), height = max(300, bounds.height)
        let scale = min(1, screen.width * 0.8 / width, screen.height * 0.8 / height)
        return window.frameRect(forContentRect: CGRect(x: 0, y: 0, width: width * scale, height: height * scale)).size
    }
    func arrange(restoreMinimized: Bool = false) {
        let ordered = order.compactMap { id in windows[id].map { (id, $0) } }
        if restoreMinimized {
            for (_, window) in ordered where window.isMiniaturized { window.deminiaturize(nil) }
        }
        // Respect windows moved to another monitor, and the menu bar/Dock on each.
        let screens = Dictionary(grouping: ordered.filter { restoreMinimized || !$0.1.isMiniaturized }) { $0.1.screen ?? NSScreen.main }
        for (screen, group) in screens {
            let area = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
            let sizes = group.map { preferredSize($0.0, window: $0.1, screen: area) }
            let frames = LocalMacWindowLayout.frames(sizes: sizes, in: area)
            for ((id, window), frame) in zip(group, frames) {
                // Large collections may need cells below the normal resize minimum.
                window.minSize = NSSize(width: min(320, frame.width), height: min(220, frame.height))
                window.setFrame(frame, display: true)
                automaticFrames[id] = window.frame
            }
        }
    }
    private func findSurface(_ view: NSView?) -> LocalMacImageView? {
        if let surface = view as? LocalMacImageView { return surface }
        return view?.subviews.lazy.compactMap { self.findSurface($0) }.first
    }
    func dismiss(_ id: UUID) {
        receivedFrames.remove(id)
        order.removeAll { $0 == id }; automaticFrames.removeValue(forKey: id)
        guard let window = windows.removeValue(forKey: id) else { return }
        window.delegate = nil
        window.close()
    }
    func dismissAll() { for id in Array(windows.keys) { dismiss(id) } }
    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let surface = findSurface(window.contentView) else { return }
        window.makeFirstResponder(surface)
        surface.activateWindow()
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let id = windows.first(where: { $0.value === window })?.key else { return }
        windows.removeValue(forKey: id); receivedFrames.remove(id)
        order.removeAll { $0 == id }; automaticFrames.removeValue(forKey: id)
        runtime?.closeWindowPreview(id)
    }
}
