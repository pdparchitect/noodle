import AppKit
import BrowserBridge
import BrowserCore
import NoodleLaunchChecks
import SwiftUI

/// Opt-in signed fixture. Never loads user profiles or starts the provider.
@MainActor enum BrowserUITest {
    static func runAndExit(delegate: BrowserAppDelegate) async {
        setbuf(stdout, nil)
        NSApp.accessibilitySetValue(true, forAttribute: .init(rawValue: "AXEnhancedUserInterface"))
        do {
            let library = delegate.library, presentation = delegate.presentation
            print("BROWSER_UI_ARTIFACTS: \(library.root.path)")
            if LaunchChecks.current.contains(BrowserLaunchCheck.cleanupUI) {
                for profile in library.profiles { try await delegate.runtime.removeBrowser(profile.id) }
                try FileManager.default.removeItem(at: library.root)
                print("BROWSER_UI_CLEANED"); exit(0)
            }
            let work = try library.create(name: "Work"), research = try library.create(name: "Research")
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
            presentation.selection = research.id
            try await Task.sleep(for: .milliseconds(800))
            guard library.profiles.count == 2, NSApp.windows.filter({ $0.identifier?.rawValue == "library" }).count == 1 else {
                throw BrowserError("Selecting a browser created a separate browser window.")
            }
            presentation.selection = work.id
            try await Task.sleep(for: .milliseconds(800))
            guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { throw BrowserError("Missing application menu.") }
            appMenu.update()
            guard appMenu.items.contains(where: { $0.title == "Check for Updates" }),
                  let settings = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," }) else { throw BrowserError("Missing suite Settings or Check for Updates commands.") }
            guard NSApp.mainMenu?.items.contains(where: { $0.title == "Browser" }) == true,
                  NSApp.mainMenu?.items.contains(where: { $0.title == "Window" }) == true,
                  NSApp.mainMenu?.items.contains(where: { $0.title == "Help" }) == true else { throw BrowserError("Missing standard browser/window/help menus.") }
            appMenu.performActionForItem(at: settings)
            try await Task.sleep(for: .milliseconds(650))
            guard let settingsWindow = NSApp.windows.first(where: { $0.isVisible && ($0.identifier?.rawValue.contains("Settings") == true || $0.title == "Settings" || $0.title == "General") }) else {
                throw BrowserError("Command-comma did not open the suite Settings scene.")
            }
            guard settingsWindow.toolbar?.items.contains(where: { $0.label == "Update" && $0.action != nil }) == true else {
                throw BrowserError("Missing native Update settings tab.")
            }
            settingsWindow.close()
            try await verifyWebSurface(presentation, window: window)
            try await verifyTabTargets(presentation, window: window)
            try await verifyPersonRow(presentation, window: window)
            // Delete the currently displayed profile while its window is mounted.
            // This catches retained WKWebViews that prevent data-store removal.
            try await BrowserSmokeTest.eventually("the selected webpage mounted before deletion") { presentation.currentTab?.web.window === window }
            for profile in library.profiles { try await delegate.runtime.removeBrowser(profile.id) }
            window.close()
            delegate.runtime.shutdown()
            print("BROWSER_UI_PASSED: web surface, tab padding input, empty tab strip double-click, independent tab closing, single window, Settings, Update and standard menus, deletion while mounted")
            print("BROWSER_UI_ARTIFACTS: \(library.root.path)")
            exit(0)
        } catch { fputs("BROWSER_UI_FAILED: \(error.localizedDescription)\n", stderr); exit(1) }
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
    /// The person a Hub keeps browsers for heads their group; clicking them selects nothing.
    private static func verifyPersonRow(_ presentation: BrowserPresentation, window: NSWindow) async throws {
        guard let content = window.contentView, let selected = presentation.selection else { throw BrowserError("Missing sidebar fixture.") }
        let runtime = presentation.runtime, hubID = BrowserBuildIdentity.current.hubID
        var create = BrowserRequest(.create); create.profile = BrowserDraft(name: "Kept")
        let kept = try await runtime.perform(create, caller: hubID).browser!
        var owner = BrowserRequest(.setOwner, browserID: kept.id); owner.owner = BrowserOwner(id: UUID(), name: "Ada")
        _ = try await runtime.perform(owner, caller: hubID)
        try await BrowserSmokeTest.eventually("person row key window") { NSApp.isActive && window.isKeyWindow }
        try await BrowserSmokeTest.eventually("person row layout") {
            content.layoutSubtreeIfNeeded()
            return elements(content).contains { attribute($0, .title) as? String == "Ada" || attribute($0, .description) as? String == "Ada" }
        }
        guard let row = elements(content).first(where: { attribute($0, .title) as? String == "Ada" || attribute($0, .description) as? String == "Ada" }),
              let frame = (row.value(forKey: "accessibilityFrame") as? NSValue)?.rectValue, !frame.isEmpty else {
            throw BrowserError("Missing accessible person row.")
        }
        try click(window.convertPoint(fromScreen: .init(x: frame.midX, y: frame.midY)), in: window)
        try await Task.sleep(for: .milliseconds(600))
        guard presentation.selection == selected, runtime.failure == nil else {
            throw BrowserError("Clicking a person selected them as a browser: \(runtime.failure ?? "no alert").")
        }
        // Arrow keys walk past the person too, down to the browser kept for them and back.
        guard let list = elements(content).compactMap({ $0 as? NSTableView }).first else { throw BrowserError("Missing sidebar list.") }
        window.makeFirstResponder(list)
        var visited: Set<UUID> = []
        for key in [125, 125, 125, 126, 126, 126] as [UInt16] {
            guard let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: key) else {
                throw BrowserError("Could not create fixture key input.")
            }
            NSApp.postEvent(down, atStart: false)
            try await Task.sleep(for: .milliseconds(400))
            guard let id = presentation.selection, presentation.library.profiles.contains(where: { $0.id == id }), runtime.failure == nil else {
                throw BrowserError("Arrow keys selected a person as a browser: \(runtime.failure ?? "no alert").")
            }
            visited.insert(id)
        }
        guard visited.contains(kept.id) else { throw BrowserError("Arrow keys did not reach the browser kept for a person.") }
        presentation.selection = selected
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
    private static func verifyWebSurface(_ presentation: BrowserPresentation, window: NSWindow) async throws {
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
        try await tab.click(target: "#save", x: nil, y: nil, frame: nil)
        try await BrowserSmokeTest.eventually("native input in the library window") {
            try await tab.evaluate("return document.querySelector('#save').textContent;") as? String == "Saved"
        }
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
