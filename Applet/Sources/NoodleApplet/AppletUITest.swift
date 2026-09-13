import AppKit
import AppletBridge
import AppletCore

@MainActor enum AppletUITest {
    /// Run in a signed bundle with --noodle-background --background-launch-ui-test.
    /// Exercise Launch Services against this process without starting the shared provider.
    static func runBackgroundLaunch() async throws {
        setbuf(stdout, nil)
        func libraryIsVisible() -> Bool {
            NSApp.windows.contains { $0.identifier?.rawValue == "library" && $0.isVisible }
        }
        func open(_ configuration: NSWorkspace.OpenConfiguration) async throws {
            configuration.allowsRunningApplicationSubstitution = false
            let app = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                configuration: configuration)
            guard app.processIdentifier == getpid() else { throw AppletError("Launch did not reuse the test process") }
            try await Task.sleep(for: .milliseconds(700))
        }
        func openInBackground() async throws {
            let app = try await AppletLaunch.openInBackground(at: Bundle.main.bundleURL)
            guard app.processIdentifier == getpid() else { throw AppletError("Background launch did not reuse the test process") }
            try await Task.sleep(for: .milliseconds(700))
        }
        try await Task.sleep(for: .milliseconds(700))
        guard !libraryIsVisible() else { throw AppletError("Background startup opened the library") }
        for _ in 0..<3 { try await openInBackground() }
        guard !libraryIsVisible(), !NSApp.isActive else {
            throw AppletError("Background reuse opened the library or activated the app")
        }
        print("PASS: background startup and repeated Launch Services requests keep the catalogue closed")

        try await open(NSWorkspace.OpenConfiguration())
        guard libraryIsVisible() else { throw AppletError("Explicit app open did not show the library") }
        try await openInBackground()
        guard libraryIsVisible() else { throw AppletError("Background request hid an already open library") }
        NSApp.windows.first { $0.identifier?.rawValue == "library" }?.close()
        NSApp.hide(nil)
        try await openInBackground()
        guard !libraryIsVisible() else {
            throw AppletError("Background request reopened a closed library")
        }
        print("PASS: explicit app open shows the library; a later background request leaves it closed")

        let creation = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 240, height: 180),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        creation.isReleasedWhenClosed = false
        creation.title = "Background launch test creation"
        creation.makeKeyAndOrderFront(nil)
        NSApp.unhide(nil)
        defer { creation.close() }
        try await openInBackground()
        guard creation.isVisible, !NSApp.isHidden, !libraryIsVisible() else {
            throw AppletError("Background request hid an existing window or opened the library")
        }
        print("PASS: background requests preserve existing creation windows")
    }

    /// Opt-in observation for real Launch Services app/URL launches. No window actions.
    static func captureLaunch(isDefault: Bool?, external: Bool) {
        let windows = NSApp.windows.filter(\.isVisible).map {
            ["title": $0.title, "id": $0.identifier?.rawValue ?? ""]
        }
        let report: [String: Any] = ["defaultLaunch": isDefault ?? false, "external": external,
            "windows": windows, "processID": ProcessInfo.processInfo.processIdentifier]
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-applet-launch-check.json")
        try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
    }
    static func run() async throws {
        setbuf(stdout, nil)
        var options = NoodletWindowOptions()
        options.type = .preview; options.background = .translucent
        options.width = 320; options.height = 350; options.minWidth = 260; options.minHeight = 300
        options.maxWidth = 480; options.maxHeight = 520; options.resizable = false; options.rememberFrame = true
        let key = "ui-test-" + UUID().uuidString
        let panel = WindowPresentation.make(options, size: options.size())
        WindowPresentation.apply(options, to: panel, content: NSView(), size: options.size(), key: key, remember: false)
        guard panel is NSPanel, panel.level == .floating, !panel.styleMask.contains(.resizable),
            !panel.isOpaque, panel.contentView is NSVisualEffectView,
            panel.contentMinSize == CGSize(width:260,height:300), panel.contentMaxSize == CGSize(width:480,height:520),
            panel.frameAutosaveName.isEmpty else { throw AppletError("Preview window policy mismatch") }
        panel.close()
        options.type = .standard; options.resizable = true
        let first = WindowPresentation.make(options, size: options.size())
        WindowPresentation.apply(options, to: first, content: NSView(), size: options.size(), key: key, remember: true)
        first.setContentSize(CGSize(width:400,height:440)); first.saveFrame(usingName: "Noodlet." + key); first.close()
        let restored = WindowPresentation.make(options, size: options.size())
        WindowPresentation.apply(options, to: restored, content: NSView(), size: options.size(), key: key, remember: true)
        guard restored.contentRect(forFrameRect:restored.frame).size == CGSize(width:400,height:440) else { throw AppletError("Saved window size was not restored") }
        restored.close(); NSWindow.removeFrame(usingName: "Noodlet." + key)
        print("PASS: preview panel, native translucency, resize limits and frame restoration")
        NSApp.activate()
        try await Task.sleep(for: .milliseconds(600))
        guard let menu = NSApp.mainMenu?.items.first?.submenu else {
            throw AppletError("Application menu missing")
        }
        menu.update()
        guard let file = NSApp.mainMenu?.items.first(where: { $0.title == "File" })?.submenu,
              file.items.contains(where: { $0.title == "Open Library" }),
              file.items.contains(where: { $0.title == "Open Noodlet…" }) else {
            throw AppletError("File menu must expose Open Library and Open Noodlet")
        }
        let titles = menu.items.map(\.title)
        print("APPLICATION MENU: \(titles)")
        guard titles.contains("About Noodle Applet"), titles.contains("Check for Updates…"),
            let settings = menu.items.firstIndex(where: {
                $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command)
            })
        else {
            throw AppletError(
                "Application menu must expose About, Settings (⌘,) and Check for Updates")
        }
        guard let update = titles.firstIndex(of: "Check for Updates…"), update < settings,
            menu.items[(update + 1)..<settings].allSatisfy({ $0.isSeparatorItem }),
            let help = NSApp.mainMenu?.items.first(where: { $0.title == "Help" })?.submenu,
            help.items.contains(where: { $0.title == "Noodle Applet Help" })
        else {
            throw AppletError("Update menu ordering or repository Help item differs from Computer")
        }
        guard let library = NSApp.windows.first(where: { $0.identifier?.rawValue == "library" }),
            library.toolbar != nil
        else { throw AppletError("Native library toolbar missing") }
        let search = library.toolbar?.items.first(where: { $0.itemIdentifier.rawValue.contains("applet-search") })?.view
        if let search {
            guard search.convert(search.bounds, to:nil).midX > library.frame.width * 0.65 else {
                throw AppletError("Search must be on the right of the toolbar")
            }
            print("PASS: search is on the right of the actual native toolbar")
        } else { throw AppletError("Search toolbar item is missing") }
        menu.performActionForItem(at: settings)
        try await Task.sleep(for: .milliseconds(800))
        guard
            let window = NSApp.windows.first(where: {
                $0.isVisible
                    && ($0.identifier?.rawValue.contains("Settings") == true
                        || $0.title == "Settings" || $0.title == "Update")
            }), let content = window.contentView
        else {
            throw AppletError("Settings command did not open the native Settings scene")
        }
        content.layoutSubtreeIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            throw AppletError("Settings snapshot unavailable")
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let snapshot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "noodle-applet-update-settings.png")
        try bitmap.representation(using: .png, properties: [:])?.write(to: snapshot)
        print(
            "PASS: actual application menu includes Check for Updates and Settings; ⌘, command opens native Settings scene"
        )
        print("SETTINGS SNAPSHOT: \(snapshot.path)")
    }

}
