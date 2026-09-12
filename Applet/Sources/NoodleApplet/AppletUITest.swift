import AppKit
import AppletBridge
import AppletCore

@MainActor enum AppletUITest {
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
