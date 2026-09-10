import AppKit

@main struct PreviewGeometryTests {
    @MainActor static func main() {
        let primary = NSRect(x: 0, y: 25, width: 1440, height: 875)
        let secondary = NSRect(x: -1920, y: 0, width: 1920, height: 1080)
        let saved = NSRect(x: 100, y: 110, width: 1000, height: 700)
        precondition(ComputerPreviewGeometry.fitting(saved, screens: [primary], preferred: primary) == saved)
        let onSecondary = NSRect(x: -1800, y: 80, width: 1100, height: 850)
        precondition(ComputerPreviewGeometry.fitting(onSecondary, screens: [primary, secondary], preferred: primary) == onSecondary)
        precondition(primary.contains(ComputerPreviewGeometry.fitting(onSecondary, screens: [primary], preferred: primary)))
        let huge = NSRect(x: 10000, y: -10000, width: 4000, height: 3000)
        precondition(ComputerPreviewGeometry.fitting(huge, screens: [primary], preferred: primary) == primary)
        let tiny = NSRect(x: 1430, y: 890, width: 20, height: 20)
        let fitted = ComputerPreviewGeometry.fitting(tiny, screens: [primary], preferred: primary)
        precondition(fitted.size == NSSize(width: 480, height: 320) && primary.contains(fitted))

        // Actual AppKit save/reopen round trip in a private preferences suite.
        _ = NSApplication.shared
        let suite = "NoodlePreviewGeometryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = NSWindow(contentRect: saved, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false
        ComputerPreviewGeometry.save(first, defaults: defaults)
        let stored = first.frame
        first.close()
        let second = NSWindow(contentRect: .zero, styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        second.isReleasedWhenClosed = false
        ComputerPreviewGeometry.restore(second, preferredScreen: NSScreen.main, defaults: defaults)
        let screens = NSScreen.screens.map(\.visibleFrame)
        if let main = NSScreen.main {
            precondition(second.frame == ComputerPreviewGeometry.fitting(stored, screens: screens, preferred: main.visibleFrame))
        }
        defaults.set(["x": "invalid"], forKey: ComputerPreviewGeometry.key)
        ComputerPreviewGeometry.restore(second, preferredScreen: NSScreen.main, defaults: defaults)
        precondition(second.frame.width > 0 && second.frame.height > 0)
        second.close()
        print("PASS: frame save/reopen, minimum size, multi-monitor placement, removed monitor, oversized and invalid preferences")
    }
}
