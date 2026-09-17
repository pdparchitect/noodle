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
    static func frames(count: Int, in visibleFrame: CGRect) -> [CGRect] {
        guard count > 0 else { return [] }
        let area = visibleFrame.insetBy(dx: 12, dy: 12), gap: CGFloat = 12
        // Prefer landscape cells, accounting for unused cells in the last row.
        let columns = (1...count).min { first, second in
            func score(_ columns: Int) -> CGFloat {
                let rows = (count + columns - 1) / columns
                let width = (area.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
                let height = (area.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
                guard width > 0, height > 0 else { return .infinity }
                return abs(log(width / height / 1.5)) + CGFloat(columns * rows - count) / CGFloat(count)
            }
            return score(first) < score(second)
        } ?? 1
        let rows = (count + columns - 1) / columns
        let height = (area.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
        return (0..<count).map { index in
            let row = index / columns, column = index % columns
            let rowCount = min(columns, count - row * columns)
            let width = (area.width - gap * CGFloat(rowCount - 1)) / CGFloat(rowCount)
            return CGRect(x: area.minX + CGFloat(column) * (width + gap),
                          y: area.maxY - CGFloat(row + 1) * height - CGFloat(row) * gap,
                          width: width, height: height)
        }
    }
}

/// Owned by the connection, not the currently selected desktop view. These are
/// ordinary independent windows, so changing computers/files/terminals keeps them.
@MainActor final class LocalMacWindowPreviewPresenter: NSObject, NSWindowDelegate {
    private weak var runtime: LocalMacComputer?
    private(set) var windows: [UUID: NSWindow] = [:]
    private var order: [UUID] = []
    private var sized: Set<UUID> = []
    private var initialFrames: [UUID: CGRect] = [:]
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
            initialFrames[id] = window.frame
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
        guard let geometry = runtime?.windowPreviews[id]?.geometry, let window = windows[id], !sized.contains(id) else { return }
        sized.insert(id)
        // A delayed first frame must not undo tiling or a manual move/resize.
        if initialFrames.removeValue(forKey: id) == window.frame {
            let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
            let width = max(480, geometry.bounds.width), height = max(300, geometry.bounds.height)
            let scale = min(1, screen.width * 0.8 / width, screen.height * 0.8 / height)
            window.setContentSize(NSSize(width: width * scale, height: height * scale))
            window.setFrameOrigin(CGPoint(x: screen.midX - window.frame.width / 2, y: screen.midY - window.frame.height / 2))
        }
        if let surface = findSurface(window.contentView) { window.makeFirstResponder(surface) }
    }
    func arrange(restoreMinimized: Bool = false) {
        let ordered = order.compactMap { id in windows[id].map { (id, $0) } }
        if restoreMinimized {
            for (_, window) in ordered where window.isMiniaturized { window.deminiaturize(nil) }
        }
        // Respect windows moved to another monitor, and the menu bar/Dock on each.
        let screens = Dictionary(grouping: ordered.filter { restoreMinimized || !$0.1.isMiniaturized }) { $0.1.screen ?? NSScreen.main }
        for (screen, group) in screens where group.count > 1 {
            let area = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1200, height: 800)
            let frames = LocalMacWindowLayout.frames(count: group.count, in: area)
            for ((id, window), frame) in zip(group, frames) {
                sized.insert(id); initialFrames.removeValue(forKey: id)
                // Large collections may need cells below the normal resize minimum.
                window.minSize = NSSize(width: min(320, frame.width), height: min(220, frame.height))
                window.setFrame(frame, display: true)
            }
        }
    }
    private func findSurface(_ view: NSView?) -> LocalMacImageView? {
        if let surface = view as? LocalMacImageView { return surface }
        return view?.subviews.lazy.compactMap { self.findSurface($0) }.first
    }
    func dismiss(_ id: UUID) {
        sized.remove(id)
        order.removeAll { $0 == id }; initialFrames.removeValue(forKey: id)
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
        windows.removeValue(forKey: id); sized.remove(id)
        order.removeAll { $0 == id }; initialFrames.removeValue(forKey: id)
        runtime?.closeWindowPreview(id)
    }
}
