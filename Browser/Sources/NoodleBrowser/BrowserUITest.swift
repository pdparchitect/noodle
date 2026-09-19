import AppKit
import BrowserBridge
import BrowserCore
import SwiftUI
import ScreenCaptureKit

/// Opt-in signed fixture. Never loads user profiles or starts the provider.
@MainActor enum BrowserUITest {
    static func runAndExit(delegate: BrowserAppDelegate) async {
        setbuf(stdout, nil)
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        do {
            let library = delegate.library, presentation = delegate.presentation
            print("BROWSER_UI_ARTIFACTS: \(library.root.path)")
            if CommandLine.arguments.contains("--cleanup-ui") {
                for profile in library.profiles { try await delegate.runtime.removeBrowser(profile.id) }
                try FileManager.default.removeItem(at: library.root)
                print("BROWSER_UI_CLEANED"); exit(0)
            }
            var work = try library.create(name: "Work"), research = try library.create(name: "Research")
            work.symbol = "briefcase.fill"; work.backgroundPreset = "ocean"
            research.symbol = "sparkles"; research.colour = 1; research.paused = true; research.backgroundPreset = "forest"
            try library.update(work); try library.update(research)
            try library.addBookmark(work.id, url: "https://developer.apple.com/documentation/", title: "Documentation")
            try library.addBookmark(work.id, url: "https://github.com/", title: "GitHub")
            _ = try library.recordVisit(work.id, url: "https://developer.apple.com/documentation/", title: "Apple Developer Documentation")
            presentation.selection = work.id
            for _ in 0..<30 {
                if delegate.openLibrary != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            delegate.openLibrary?()
            try await Task.sleep(for: .milliseconds(900))
            guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "library" }), window.toolbar != nil else {
                throw BrowserError("Browser must use the suite's native single-window toolbar.")
            }
            window.setContentSize(.init(width: 1180, height: 760))
            try await Task.sleep(for: .milliseconds(300))
            // An aborted run can leave a collapsed sidebar persisted; start expanded.
            if let show = sidebarToggle(window, "Show Sidebar") {
                press(show)
                try await Task.sleep(for: .milliseconds(600))
            }
            try await snapshot(window, to: library.root.appendingPathComponent("browser.png"))
            guard !window.isOpaque, let content = window.contentView,
                  containsNativeSidebar(in: content) else {
                throw BrowserError("Browser must use Computer's native glass sidebar and transparent window compositing.")
            }
            try await snapshot(window, to: library.root.appendingPathComponent("browser.png"))
            try verifyCreatePlacement(window, collapsed: false)
            try verifySettingsPlacement(window)
            try await verifyWebSurface(presentation, window: window, root: library.root)
            try await verifyTabTargets(presentation, window: window)
            guard let hide = sidebarToggle(window, "Hide Sidebar") else { throw BrowserError("Missing native sidebar toggle.") }
            press(hide)
            try await Task.sleep(for: .milliseconds(400))
            try await snapshot(window, to: library.root.appendingPathComponent("browser-collapsed.png"))
            try verifyCreatePlacement(window, collapsed: true)
            // The expanded sidebar's own toggle is hidden with it; the collapsed one must remain.
            guard let show = sidebarToggle(window, "Show Sidebar") else { throw BrowserError("Missing sidebar toggle while collapsed.") }
            press(show)
            try await Task.sleep(for: .milliseconds(600))
            try verifyCreatePlacement(window, collapsed: false)
            presentation.mode = .history
            try await Task.sleep(for: .milliseconds(350))
            try await snapshot(window, to: library.root.appendingPathComponent("history.png"))
            presentation.mode = .bookmarks
            try await Task.sleep(for: .milliseconds(350))
            try await snapshot(window, to: library.root.appendingPathComponent("bookmarks.png"))
            presentation.selection = research.id
            try await Task.sleep(for: .milliseconds(800))
            try await snapshot(window, to: library.root.appendingPathComponent("research.png"))
            guard library.profiles.count == 2, NSApp.windows.filter({ $0.identifier?.rawValue == "library" }).count == 1 else {
                throw BrowserError("Selecting a browser created a separate browser window.")
            }
            presentation.selection = work.id
            presentation.backgroundEditing = try library.profile(work.id)
            try await Task.sleep(for: .milliseconds(800))
            guard let backgroundSheet = window.attachedSheet else { throw BrowserError("Background did not open its native sheet.") }
            try await snapshot(backgroundSheet, to: library.root.appendingPathComponent("background.png"))
            presentation.backgroundEditing = nil
            try await Task.sleep(for: .milliseconds(300))
            presentation.showingNew = true
            try await Task.sleep(for: .milliseconds(600))
            guard let newSheet = window.attachedSheet, let newContent = newSheet.contentView,
                  containsTextField("Browser", in: newContent) else { throw BrowserError("New Browser must prefill a name.") }
            try await snapshot(newSheet, to: library.root.appendingPathComponent("new-browser.png"))
            guard let iconButton = elements(newContent).first(where: { attribute($0, .description) as? String == "Change Browser Icon" }) else {
                throw BrowserError("Missing browser icon button.")
            }
            press(iconButton)
            try await Task.sleep(for: .milliseconds(600))
            guard let iconSheet = newSheet.attachedSheet, let iconContent = iconSheet.contentView,
                  let done = elements(iconContent).first(where: { attribute($0, .title) as? String == "Done" || attribute($0, .description) as? String == "Done" }) else {
                throw BrowserError("The browser icon must open the suite's full native sheet.")
            }
            try await snapshot(iconSheet, to: library.root.appendingPathComponent("browser-icon.png"))
            press(done)
            try await Task.sleep(for: .milliseconds(250))
            presentation.showingNew = false
            try await Task.sleep(for: .milliseconds(300))
            presentation.editing = try library.profile(work.id)
            try await Task.sleep(for: .milliseconds(900))
            guard let sheet = window.attachedSheet else { throw BrowserError("Edit Browser did not open its native sheet.") }
            try await snapshot(sheet, to: library.root.appendingPathComponent("edit-browser.png"))
            presentation.editing = nil
            try await Task.sleep(for: .milliseconds(300))
            guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { throw BrowserError("Missing application menu.") }
            appMenu.update()
            guard appMenu.items.contains(where: { $0.title == "Check for Updates…" }),
                  let settings = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," }) else { throw BrowserError("Missing suite Settings or Check for Updates commands.") }
            guard NSApp.mainMenu?.items.contains(where: { $0.title == "Browser" }) == true,
                  NSApp.mainMenu?.items.contains(where: { $0.title == "Window" }) == true,
                  NSApp.mainMenu?.items.contains(where: { $0.title == "Help" }) == true else { throw BrowserError("Missing standard browser/window/help menus.") }
            appMenu.performActionForItem(at: settings)
            try await Task.sleep(for: .milliseconds(650))
            guard let settingsWindow = NSApp.windows.first(where: { $0.isVisible && ($0.identifier?.rawValue.contains("Settings") == true || $0.title == "Settings" || $0.title == "General") }) else {
                throw BrowserError("Command-comma did not open the suite Settings scene.")
            }
            try await snapshot(settingsWindow, to: library.root.appendingPathComponent("settings.png"))
            let generalHeight = settingsWindow.frame.height
            guard let updates = settingsWindow.toolbar?.items.first(where: { $0.label == "Update" }), let action = updates.action else {
                throw BrowserError("Missing native Update settings tab.")
            }
            NSApp.sendAction(action, to: updates.target, from: updates)
            try await Task.sleep(for: .milliseconds(650))
            // General now has four controls too; Update need not be taller.
            try await snapshot(settingsWindow, to: library.root.appendingPathComponent("updates.png"))
            guard let general = settingsWindow.toolbar?.items.first(where: { $0.label == "General" }), let generalAction = general.action else {
                throw BrowserError("Missing native General settings tab.")
            }
            NSApp.sendAction(generalAction, to: general.target, from: general)
            try await Task.sleep(for: .milliseconds(650))
            guard abs(settingsWindow.frame.height - generalHeight) < 2 else {
                throw BrowserError("Settings did not shrink back to its General content.")
            }
            settingsWindow.close()
            // Delete the currently displayed profile while its window is mounted.
            // This catches retained WKWebViews that prevent data-store removal.
            for profile in library.profiles { try await delegate.runtime.removeBrowser(profile.id) }
            try await Task.sleep(for: .milliseconds(600))
            try await snapshot(window, to: library.root.appendingPathComponent("empty-library.png"))
            window.close()
            delegate.runtime.shutdown()
            print("BROWSER_UI_PASSED: native sidebar, toolbar, tab padding input, empty tab strip double-click, independent tab closing, collapsed content, icon/edit sheets, Settings, Update and standard menus")
            print("BROWSER_UI_ARTIFACTS: \(library.root.path)")
            exit(0)
        } catch { fputs("BROWSER_UI_FAILED: \(error.localizedDescription)\n", stderr); exit(1) }
    }
    /// Create Browser follows the sidebar toggle inside the sidebar's toolbar section and
    /// leaves with the sidebar, so it never joins Back and Forward.
    private static func verifyCreatePlacement(_ window: NSWindow, collapsed: Bool) throws {
        let items = (window.toolbar?.items ?? []).filter(\.isVisible)
        let labels = collapsed ? ["Show Sidebar", "Back"] : ["Hide Sidebar", "Create", "Back"]
        let frames = labels.compactMap { toolbarItem(window, $0)?.view.map { $0.convert($0.bounds, to: nil) } }
        print("BROWSER_UI_CREATE_PLACEMENT: \(labels)=\(frames)")
        guard frames.count == labels.count, items.contains(where: { $0.label == "Create" }) != collapsed,
              zip(frames, frames.dropFirst()).allSatisfy({ $0.maxX < $1.minX }) else {
            throw BrowserError("Create Browser must follow the sidebar toggle, apart from Back and Forward: \(labels)=\(frames). Toolbar: \(describeToolbar(window))")
        }
    }
    /// macOS 26 bridges a toolbar group as one item, so a button is also found through
    /// its group and its accessibility label.
    private static func toolbarItem(_ window: NSWindow, _ label: String) -> NSToolbarItem? {
        let items = (window.toolbar?.items ?? []).filter { $0.isVisible && $0.view != nil }
        return items.first(where: { $0.label == label })
            ?? items.first(where: { ($0 as? NSToolbarItemGroup)?.subitems.contains(where: { $0.label == label }) == true })
            ?? items.first(where: { item in
                item.toolTip == label || item.view.map(elements)?.contains(where: {
                    attribute($0, .description) as? String == label || attribute($0, .title) as? String == label
                }) == true
            })
    }
    private static func describeToolbar(_ window: NSWindow) -> [String] {
        (window.toolbar?.items ?? []).map { item in
            let frame = item.view.map { $0.convert($0.bounds, to: nil) }
            let subitems = (item as? NSToolbarItemGroup)?.subitems.map(\.label) ?? []
            return "\(item.itemIdentifier.rawValue) label=\(item.label) visible=\(item.isVisible) view=\(item.view.map { String(describing: type(of: $0)) } ?? "nil") frame=\(String(describing: frame)) subitems=\(subitems)"
        }
    }
    /// The fixture hides both entry points, so the App Settings fallback must close the toolbar.
    private static func verifySettingsPlacement(_ window: NSWindow) throws {
        let items = (window.toolbar?.items ?? []).filter { $0.isVisible && $0.view != nil }
        let frames = items.map { ($0.label, $0.view.map { $0.convert($0.bounds, to: nil) } ?? .zero) }
        print("BROWSER_UI_SETTINGS_PLACEMENT: \(frames)")
        guard let settings = frames.first(where: { $0.0 == "App Settings" })?.1,
              frames.allSatisfy({ $0.0 == "App Settings" || $0.1.maxX <= settings.minX }) else {
            throw BrowserError("App Settings must be the last toolbar item: \(frames).")
        }
    }
    private static func sidebarToggle(_ window: NSWindow, _ label: String) -> NSObject? {
        toolbarItem(window, label)?.view.flatMap { view in
            elements(view).first(where: { $0 is NSButton || attribute($0, .role) as? String == "AXButton" })
        }
    }
    private static func containsNativeSidebar(in view: NSView) -> Bool {
        view is NSGlassEffectView || view.subviews.contains(where: containsNativeSidebar)
    }
    private static func attribute(_ node: NSObject, _ key: NSAccessibility.Attribute) -> Any? {
        if let value = node.accessibilityAttributeValue(key) { return value }
        let names: [NSAccessibility.Attribute: String] = [.children: "accessibilityChildren", .title: "accessibilityTitle",
            .description: "accessibilityLabel", .identifier: "accessibilityIdentifier", .role: "accessibilityRole",
            .init(rawValue: "AXChildrenInNavigationOrder"): "accessibilityChildrenInNavigationOrder"]
        guard let name = names[key], node.responds(to: NSSelectorFromString(name)) else { return nil }
        return node.value(forKey: name)
    }
    private static func elements(_ root: NSObject) -> [NSObject] {
        var pending = [root], visited = Set<ObjectIdentifier>(), result: [NSObject] = []
        while let node = pending.popLast() {
            guard visited.insert(ObjectIdentifier(node)).inserted else { continue }
            result.append(node)
            pending.append(contentsOf: attribute(node, .children) as? [NSObject] ?? [])
            pending.append(contentsOf: attribute(node, .init(rawValue: "AXChildrenInNavigationOrder")) as? [NSObject] ?? [])
            if let view = node as? NSView { pending.append(contentsOf: view.subviews) }
        }
        return result
    }
    private static func press(_ node: NSObject) {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        if node.responds(to: selector) {
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            _ = unsafeBitCast(node.method(for: selector), to: Press.self)(node, selector)
        } else { node.accessibilityPerformAction(.press) }
    }
    private static func verifyTabTargets(_ presentation: BrowserPresentation, window: NSWindow) async throws {
        guard let original = presentation.currentTab, let content = window.contentView else { throw BrowserError("Missing tab fixture.") }
        let other = try presentation.runtime.makeTab(browserID: original.browserID)
        // Start inactive to cover hosted runners. WindowFocusGuard intentionally
        // consumes an activating click; test the tab hit target after focus and
        // create the input events only after activation has completed.
        NSApp.deactivate()
        try await BrowserSmokeTest.eventually("inactive tab fixture") { !NSApp.isActive }
        NSApp.activate(ignoringOtherApps: true)
        try await BrowserSmokeTest.eventually("tab fixture application activation") { NSApp.isActive }
        window.makeKeyAndOrderFront(nil)
        try await BrowserSmokeTest.eventually("tab fixture key window") { NSApp.isActive && window.isKeyWindow }
        let identifier = "browser.tab.\(original.id)"
        try await BrowserSmokeTest.eventually("tab selection button layout") {
            content.layoutSubtreeIfNeeded()
            return elements(content).contains { attribute($0, .identifier) as? String == identifier }
        }
        guard let button = elements(content).first(where: { attribute($0, .identifier) as? String == identifier }),
              button.responds(to: NSSelectorFromString("accessibilityFrame")),
              let frame = (button.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue else {
            throw BrowserError("Missing accessible tab selection button.")
        }
        // Click inside the leading padding, outside the icon and text. Events
        // stay in this process and target only the isolated fixture window.
        let point = window.convertPoint(fromScreen: .init(x: frame.minX + 3, y: frame.midY))
        guard !frame.isEmpty, window.contentLayoutRect.contains(point) else {
            throw BrowserError("Tab padding is outside the fixture content: frame=\(frame), point=\(point).")
        }
        print("BROWSER_UI_TAB_INPUT: active=\(NSApp.isActive) key=\(window.isKeyWindow) frame=\(frame) point=\(point) selected=\(String(describing: presentation.profile?.selectedTabID))")
        try click(point, in: window)
        try await BrowserSmokeTest.eventually("clicking tab padding selects the tab") {
            presentation.profile?.selectedTabID == original.id
        }
        print("BROWSER_UI_TAB_RESULT: active=\(NSApp.isActive) key=\(window.isKeyWindow) selected=\(String(describing: presentation.profile?.selectedTabID))")
        // Double-clicking opens a tab only from the empty strip, never from a tab.
        try click(point, in: window, count: 2)
        try await Task.sleep(for: .milliseconds(500))
        guard presentation.profile?.tabs.map(\.id) == [original.id, other.id] else {
            throw BrowserError("Double-clicking a tab opened another tab.")
        }
        let frames = ["browser.tab.close.\(other.id)", "browser.tab.new"].compactMap { identifier in
            elements(content).first(where: { attribute($0, .identifier) as? String == identifier })
                .flatMap { ($0.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue }
        }
        guard frames.count == 2, frames[1].minX - frames[0].maxX > 40 else { throw BrowserError("Missing empty tab strip space.") }
        let (closeFrame, addFrame) = (frames[0], frames[1])
        let empty = window.convertPoint(fromScreen: .init(x: (closeFrame.maxX + addFrame.minX) / 2, y: frame.midY))
        print("BROWSER_UI_TAB_STRIP_INPUT: close=\(closeFrame) add=\(addFrame) point=\(empty)")
        try click(empty, in: window)
        try await Task.sleep(for: .milliseconds(500))
        guard presentation.profile?.tabs.count == 2 else { throw BrowserError("A single click on the empty tab strip opened a tab.") }
        try click(empty, in: window, count: 2)
        try await BrowserSmokeTest.eventually("double-clicking the empty tab strip opens a tab") {
            presentation.profile?.tabs.count == 3
        }
        guard let opened = presentation.profile?.tabs.last?.id, presentation.profile?.selectedTabID == opened else {
            throw BrowserError("The tab opened from the empty tab strip was not selected.")
        }
        try presentation.runtime.closeTab(browserID: original.browserID, tabID: opened)
        presentation.selectTab(original.id)
        try await Task.sleep(for: .milliseconds(300))
        guard let close = elements(content).first(where: { attribute($0, .identifier) as? String == "browser.tab.close.\(other.id)" }) else {
            throw BrowserError("Missing independent tab close button.")
        }
        press(close)
        try await BrowserSmokeTest.eventually("closing the other tab") {
            presentation.profile?.tabs.contains(where: { $0.id == other.id }) == false
        }
        guard presentation.profile?.selectedTabID == original.id else { throw BrowserError("Closing another tab changed the selected tab.") }
    }
    /// Posts `count` consecutive clicks; events stay in this process.
    private static func click(_ point: NSPoint, in window: NSWindow, count: Int = 1) throws {
        for clickCount in 1...count {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: clickCount, pressure: type == .leftMouseDown ? 1 : 0) else {
                    throw BrowserError("Could not create fixture tab input.")
                }
                NSApp.postEvent(event, atStart: false)
            }
        }
    }
    private static func containsTextField(_ value: String, in view: NSView) -> Bool {
        (view as? NSTextField)?.stringValue == value || view.subviews.contains { containsTextField(value, in: $0) }
    }
    private static func snapshot(_ window: NSWindow, to url: URL) async throws {
        // Capture only this process, as Noodle's native conversation capture does.
        // AppKit cacheDisplay omits the GPU-composited sidebar glass.
        let content = try await SCShareableContent.currentProcess
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw BrowserError("Fixture window is unavailable for capture.")
        }
        let config = SCStreamConfiguration()
        config.width = max(1, Int(target.frame.width * window.backingScaleFactor))
        config.height = max(1, Int(target.frame.height * window.backingScaleFactor))
        config.showsCursor = false; config.ignoreShadowsSingleWindow = true; config.scalesToFit = true
        config.includeChildWindows = false; config.captureResolution = .best
        let capture = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
        guard let data = NSBitmapImageRep(cgImage: capture).representation(using: .png, properties: [:]) else {
            throw BrowserError("Snapshot encoding failed.")
        }
        try data.write(to: url)
    }
    private static func verifyWebSurface(_ presentation: BrowserPresentation, window: NSWindow, root: URL) async throws {
        guard let tab = presentation.currentTab else { throw BrowserError("Missing selected tab.") }
        tab.web.loadHTMLString("""
        <!doctype html><meta name="viewport" content="width=device-width"><title>Workspace</title>
        <style>body{background:#f5f6f8;color:#202630;font:16px -apple-system;margin:0;padding:56px}h1{font-size:30px}section{background:white;border:1px solid #e1e5ea;border-radius:12px;padding:24px;max-width:580px}button{background:#1673e7;color:white;border:0;border-radius:7px;padding:10px 18px;font:inherit}input{font:inherit;padding:10px;border:1px solid #ccd1d9;border-radius:7px}p{color:#657080;line-height:1.6}</style>
        <h1>Workspace</h1><section><h2>Project notes</h2><p>Quarterly review</p>
        <input id="title" value="Draft report"><button id="save" onclick="this.textContent='Saved'">Save</button></section>
        """, baseURL: URL(string: "https://browser-fixture.invalid/"))
        for _ in 0..<50 {
            if (try? await tab.evaluate("return !!document.querySelector('#save') && document.readyState==='complete';")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(300))
        guard tab.web.window === window else { throw BrowserError("The selected webpage is not mounted in the library window.") }
        try await snapshot(window, to: root.appendingPathComponent("browser-page.png"))
        try await tab.click(target: "#save", x: nil, y: nil, frame: nil)
        try await BrowserSmokeTest.eventually("native input in the library window") {
            try await tab.evaluate("return document.querySelector('#save').textContent;") as? String == "Saved"
        }
        try await snapshot(window, to: root.appendingPathComponent("browser-page.png"))
        presentation.mode = .history
        try await Task.sleep(for: .milliseconds(200))
        guard tab.web.window !== window else { throw BrowserError("Leaving Browser view did not restore its background surface.") }
        let capture = try await tab.snapshot()
        guard NSImage(data: capture) != nil else { throw BrowserError("Background screenshot failed after changing detail view.") }
        presentation.mode = .browser
        try await Task.sleep(for: .milliseconds(200))
        guard tab.web.window === window else { throw BrowserError("Returning to Browser view lost its live tab.") }
    }
}
