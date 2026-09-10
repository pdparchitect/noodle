import AppKit

/// Standalone checks for both previews' shared download state. No network or app launch.
@main struct PreviewDownloadTests {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in await run(); exit(0) }
        app.run()
    }
    @MainActor static func run() async {
        func require(_ condition: Bool, _ message: String) {
            guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
            print("PASS: \(message)")
        }
        struct Unreleased: LocalizedError {
            var errorDescription: String? { "No public Computer release is available yet." }
        }
        var calls = 0
        var fail = true
        let view = ComputerPreviewDownload {
            calls += 1
            try await Task.sleep(for: .milliseconds(50))
            if fail { throw Unreleased() }
        }
        let surface = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        view.install(in: surface)
        let stack = view.subviews.first as! NSStackView
        let button = stack.arrangedSubviews.compactMap { $0 as? NSButton }.first!
        let message = stack.arrangedSubviews[1] as! NSTextField
        require(view.isHidden && calls == 0, "no download action during preview construction")
        view.showIfNeeded(true)
        require(!view.isHidden && calls == 0, "missing-app state offers an explicit action without downloading")
        button.performClick(nil)
        require(!button.isEnabled && button.title == "Checking…", "disable duplicate requests while checking release")
        try? await Task.sleep(for: .milliseconds(150))
        require(calls == 1 && button.isEnabled && message.stringValue.contains("No public"), "release/network errors remain visible and retryable")
        fail = false
        button.performClick(nil)
        try? await Task.sleep(for: .milliseconds(150))
        require(calls == 2 && message.stringValue.contains("reopen this preview"), "successful download action explains reconnecting after installation")
        view.showIfNeeded(false)
        require(view.isHidden, "installed app or revoked assignment does not show download state")
        view.showIfNeeded(true)
        button.performClick(nil)
        view.stop()
        try? await Task.sleep(for: .milliseconds(100))
        require(button.isEnabled && !message.stringValue.contains("cancel"), "closing preview cancels checks without showing a cancellation error")
        surface.layoutSubtreeIfNeeded()
        require(view.frame == surface.bounds && button.frame.width > 0, "overlay fills smallest preview and lays out download button")
    }
}
