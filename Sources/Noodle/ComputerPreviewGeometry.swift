import AppKit

/// One remembered frame for all Computer previews, separate from Quick Look.
@MainActor enum ComputerPreviewGeometry {
    static let key = "ComputerPreview.windowFrame.v1"

    static func save(_ window: NSWindow, defaults: UserDefaults = .standard) {
        let frame = window.frame
        guard valid(frame) else { return }
        defaults.set(["x": frame.origin.x, "y": frame.origin.y,
                      "width": frame.width, "height": frame.height], forKey: key)
    }

    static func restore(_ window: NSWindow, preferredScreen: NSScreen?, defaults: UserDefaults = .standard) {
        let saved = defaults.dictionary(forKey: key)
        let frame: NSRect?
        if let x = saved?["x"] as? Double, let y = saved?["y"] as? Double,
           let width = saved?["width"] as? Double, let height = saved?["height"] as? Double {
            let candidate = NSRect(x: x, y: y, width: width, height: height)
            frame = valid(candidate) ? candidate : nil
        } else { frame = nil }
        if frame == nil { window.center() }
        let candidate = frame ?? window.frame
        let screens = NSScreen.screens.map(\.visibleFrame)
        guard !screens.isEmpty else { return }
        let preferred = preferredScreen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? screens[0]
        window.setFrame(fitting(candidate, screens: screens, preferred: preferred), display: false)
    }

    static func fitting(_ frame: NSRect, screens: [NSRect], preferred: NSRect) -> NSRect {
        let visible = screens.max { intersectionArea(frame, $0) < intersectionArea(frame, $1) }
        let screen = visible.flatMap { intersectionArea(frame, $0) > 0 ? $0 : nil } ?? preferred
        let width = min(max(frame.width, 480), screen.width)
        let height = min(max(frame.height, 320), screen.height)
        return NSRect(x: min(max(frame.minX, screen.minX), screen.maxX - width),
                      y: min(max(frame.minY, screen.minY), screen.maxY - height),
                      width: width, height: height)
    }

    private static func valid(_ frame: NSRect) -> Bool {
        [frame.minX, frame.minY, frame.width, frame.height].allSatisfy(\.isFinite)
            && frame.width > 0 && frame.height > 0
    }
    private static func intersectionArea(_ lhs: NSRect, _ rhs: NSRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        return intersection.isNull ? 0 : intersection.width * intersection.height
    }
}
