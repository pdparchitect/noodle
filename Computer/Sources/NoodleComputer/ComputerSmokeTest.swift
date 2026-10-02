import AppKit
import ComputerCore
import ComputerBridge
import CryptoKit
import Foundation
import Virtualization
import Surface
import SwiftUI

/// Opt-in signed-app integration fixture. Never opens the user's computer library.
@MainActor enum ComputerSmokeTest {
    static func checkUpdaterUI() async throws {
        setbuf(stdout, nil)
        NSApp.activate()
        try await Task.sleep(for: .milliseconds(600))
        guard let menu = NSApp.mainMenu?.items.first?.submenu else { throw ComputerError("Application menu missing") }
        menu.update()
        let titles = menu.items.map(\.title)
        print("APPLICATION MENU: \(titles)")
        guard titles.contains("About \(ComputerAppIdentity.name)"), titles.contains("Check for Updates"),
              let settings = menu.items.firstIndex(where: { $0.keyEquivalent == "," && $0.keyEquivalentModifierMask.contains(.command) }) else {
            throw ComputerError("Application menu must expose About, Settings (⌘,) and Check for Updates")
        }
        menu.performActionForItem(at: settings)
        try await Task.sleep(for: .milliseconds(800))
        guard let window = NSApp.windows.first(where: {
            $0.isVisible && ($0.identifier?.rawValue.contains("Settings") == true || $0.title == "Settings" || $0.title == "Update")
        }), let content = window.contentView else {
            throw ComputerError("Settings command did not open the native Settings scene")
        }
        content.layoutSubtreeIfNeeded()
        guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { throw ComputerError("Settings snapshot unavailable") }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let snapshot = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-computer-update-settings.png")
        try bitmap.representation(using: .png, properties: [:])?.write(to: snapshot)
        print("PASS: actual application menu includes Check for Updates and Settings; ⌘, command opens native Settings scene")
        print("SETTINGS SNAPSHOT: \(snapshot.path)")
    }

    #if NOODLE_DEV_HOOKS
    static func checkProvider() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoodleProvider-Test-\(UUID().uuidString)")
        let store = try ComputerStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshotTest = ComputerLaunchCheck.requested(ComputerLaunchCheck.providerSnapshot)
        var computer = (snapshotTest ? ComputerTemplate.desktop : .shell).makeComputer(name: "Isolated Provider Test")
        computer.networkEnabled = snapshotTest
        print("PROVIDER TEST: preparing isolated \(snapshotTest ? "desktop snapshot" : "Alpine shell")")
        guard await store.create(computer, source: nil), let session = store.selected else {
            throw ComputerError(store.error ?? "Could not create the fixture.")
        }
        do {
            let socket = try ComputerConnection.socketURL().deletingLastPathComponent().appendingPathComponent("t.sock")
            store.provider = try ComputerProvider(store: store, socket: socket)
            let finished = socket.deletingLastPathComponent().appendingPathComponent("fixture-finished")
            if FileManager.default.fileExists(atPath: finished.path) { try FileManager.default.removeItem(at: finished) }
            print("PROVIDER TEST READY: \(session.id)")
            if CommandLine.arguments.contains("--noodle-background") {
                guard NSApp.isHidden || NSApp.windows.allSatisfy({ !$0.isVisible }) else {
                    throw ComputerError("Background launch displayed a window: \(NSApp.windows.filter(\.isVisible).map { String(describing: type(of: $0)) + ":" + $0.title })")
                }
                print("PASS: background provider ready with no visible window; fixture computer powered off")
            }
            if snapshotTest {
                await store.start(session)
                guard session.phase == .running, let display = session.display, let runtime = session.container else {
                    throw ComputerError("The isolated desktop did not start.")
                }
                let fixture = try await runtime.execute(#"""
                    command -v xterm && for n in 1 2 3 4 5 6 7 8 9 10; do pgrep -x openbox >/dev/null && break; sleep 1; done
                    setsid xterm -geometry 70x20+40+60 -title 'Preview Verification' -e /bin/sh -c 'printf "Native desktop preview\nServed from the guest\n"; sleep 180' </dev/null >/tmp/noodle-preview-xterm.log 2>&1 &
                    """#)
                print("SNAPSHOT FIXTURE: \(fixture)")
                let began = ProcessInfo.processInfo.systemUptime
                // The Mac's view of the desktop cannot be captured; this is the guest's own frame.
                guard let image = await ComputerPreviewSnapshot.capture(frame: { try await display.surface.frame().image }) else {
                    throw ComputerError("Ready real desktop must produce a snapshot, not a fallback")
                }
                guard ProcessInfo.processInfo.systemUptime - began < 9 else {
                    throw ComputerError("Desktop snapshot exceeded its deadline.")
                }
                let ext = image.starts(with: [137, 80, 78, 71]) ? "png" : "jpg"
                let output = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-desktop-snapshot-test.\(ext)")
                try image.write(to: output)
                print("PASS: real background desktop snapshot saved to \(output.path)")
            }
            for _ in 0..<(snapshotTest ? 0 : 600) {
                if FileManager.default.fileExists(atPath: finished.path) {
                    try? FileManager.default.removeItem(at: finished)
                    break
                }
                try await Task.sleep(for: .seconds(1))
            }
            store.provider = nil
            await store.stop(session, force: true)
            print("PROVIDER TEST: fixture stopped and removed")
        } catch { await store.stop(session, force: true); throw error }
    }
    static func checkLibraryLayout() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoodleLibraryLayout-\(UUID().uuidString)")
        let store = try ComputerStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = ComputerSession(ComputerTemplate.shell.makeComputer())
        session.phase = .running
        session.terminal = GuestTerminal()
        store.sessions = [session]
        store.selection = session.id
        let host = NSHostingView(rootView: ComputerLibraryView(store: store))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 650),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "library-layout-verification")
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        func find(in view: NSView, matching predicate: (NSView) -> Bool) -> NSView? {
            if predicate(view) { return view }
            return view.subviews.compactMap { find(in: $0, matching: predicate) }.first
        }
        for size in [NSSize(width: 1000, height: 650), NSSize(width: 1001, height: 651)] {
            window.setContentSize(size)
            try await Task.sleep(for: .milliseconds(400))
            host.layoutSubtreeIfNeeded()
            guard let glass = find(in: host, matching: { String(describing: type(of: $0)).contains("ConcentricGlassEffectView") }) else {
                throw ComputerError("Native sidebar missing from full-library fixture")
            }
            guard let display = find(in: host, matching: { $0 is ComputerTerminalSurface }) else {
                throw ComputerError("Terminal missing from full-library fixture")
            }
            let sidebarFrame = glass.convert(glass.bounds, to: nil)
            let displayFrame = display.convert(display.bounds, to: nil)
            guard abs(sidebarFrame.minY - displayFrame.minY) < 0.01 else {
                throw ComputerError("Sidebar/display bottom bounds differ: \(sidebarFrame), \(displayFrame)")
            }
            print("PASS: full-library terminal bottom matches native glass at \(displayFrame.minY), size \(size)")
        }
    }

    static func checkEmptyLibraryBackground() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoodleEmptyLibrary-\(UUID().uuidString)")
        let store = try ComputerStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let host = NSHostingView(rootView: ComputerLibraryView(store: store))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 1000, height: 650),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Empty Library Verification"
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "empty-library-verification")
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: name)
            let session = ComputerSession(ComputerTemplate.shell.makeComputer(name: "Unstarted fixture"))
            for state in ["empty", "selected", "deselected", "removed"] {
                store.sessions = state == "empty" || state == "removed" ? [] : [session]
                store.selection = state == "selected" ? session.id : nil
                try await Task.sleep(for: .milliseconds(400))
                host.layoutSubtreeIfNeeded()
                guard !window.isOpaque, window.backgroundColor.alphaComponent == 0 else {
                    throw ComputerError("Fixture must exercise the transparent compositing window")
                }
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                    throw ComputerError("Could not allocate library snapshot")
                }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                // Sample blank detail areas away from controls; the view itself
                // must paint opaque pixels, not rely on the desktop behind it.
                for (x, y) in [(0.9, 0.2), (0.9, 0.8), (0.55, 0.85)] {
                    guard let colour = bitmap.colorAt(x: Int(Double(bitmap.pixelsWide) * x),
                                                      y: Int(Double(bitmap.pixelsHigh) * y)),
                          colour.alphaComponent > 0.99 else {
                        throw ComputerError("Transparent library background: \(name.rawValue), \(state)")
                    }
                }
                if state == "empty", let png = bitmap.representation(using: .png, properties: [:]) {
                    let output = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-empty-library-\(name.rawValue).png")
                    try png.write(to: output)
                    print("SNAPSHOT: \(output.path)")
                }
                print("PASS: opaque library background — \(name.rawValue), \(state)")
            }
        }
    }

    static func checkAppearancePreview() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoodleAppearance-\(UUID().uuidString)")
        let store = try ComputerStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        var computer = ComputerTemplate.shell.makeComputer(name: "Appearance Verification")
        var appearance = ComputerAppearance()
        appearance.backgroundPreset = "ocean"
        appearance.iconSymbol = "globe"
        appearance.iconColour = 1
        appearance.terminalOpacity = 0
        appearance.terminalForeground = "33FF99"
        computer.appearance = appearance
        let session = ComputerSession(computer)
        session.phase = .running
        let terminal = GuestTerminal()
        session.terminal = terminal
        terminal.view.feed(text: "Transparent terminal\r\n/workspace # Hello, world!\r\n")
        store.sessions = [session]
        store.selection = session.id
        let host = NSHostingView(rootView: ComputerLibraryView(store: store))
        let window = NSWindow(contentRect: NSRect(x: 180, y: 140, width: 1000, height: 650),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Noodle Appearance Verification"
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "appearance-verification")
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .seconds(1))
        print("APPEARANCE WINDOW: \(window.windowNumber)")
        print("APPEARANCE: terminal=\(terminal.view.backgroundOpacity), layer=\(terminal.view.layer?.backgroundColor?.alpha ?? -1), opaque=\(window.isOpaque)")
        try await Task.sleep(for: .seconds(45))
    }

    static func checkCreationForm() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoodleForm-Test-\(UUID().uuidString)")
        let store = try ComputerStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 320),
                             styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: NewComputerView(store: store))
        sheet.contentView = host
        parent.orderBack(nil)
        parent.beginSheet(sheet, completionHandler: nil)
        defer { parent.endSheet(sheet); sheet.orderOut(nil); parent.orderOut(nil) }
        func click(_ point: NSPoint) {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: sheet.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) {
                    sheet.sendEvent(event)
                }
            }
        }
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        let collapsed = sheet.contentRect(forFrameRect: sheet.frame).height
        // The 40-point appearance row and 16-point gap now sit below Advanced.
        // Add those to the outer padding, group padding and half label height.
        // Exercise the label, chevron and row's trailing empty space.
        for x: CGFloat in [90, 38, 480] {
            click(NSPoint(x: x, y: 100))
            try await Task.sleep(for: .milliseconds(250))
            let expanded = sheet.contentRect(forFrameRect: sheet.frame).height
            guard expanded > collapsed + 100 else { throw ComputerError("Advanced Options did not expand the sheet.") }
            click(NSPoint(x: x, y: 100 + expanded - collapsed))
            try await Task.sleep(for: .milliseconds(250))
            guard abs(sheet.contentRect(forFrameRect: sheet.frame).height - collapsed) < 2 else {
                throw ComputerError("The sheet did not shrink after collapse.")
            }
        }
        print("FORM TEST PASSED: label, chevron and row whitespace clicks; three expand/collapse cycles and sheet height restoration")
        try await checkDesktopToolbarLayout(store: store)
        try await checkIconEditor()
        try await checkStopConfirmation()
        try await checkAppearanceSheetSizing()
        try checkToolbarSymbolSizing()
        try checkTerminalScrollIndicator()
        try checkApplicationNaming()
    }

    private static func checkApplicationNaming() throws {
        let displayName = ComputerAppIdentity.name
        guard Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String == displayName,
              Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == displayName,
              Bundle.main.bundleURL.lastPathComponent == "\(displayName).app" else {
            throw ComputerError("The menu bar, Finder and bundle must all use the full application name.")
        }
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              appMenu.items.contains(where: { $0.title == "About \(ComputerAppIdentity.name)" }) else {
            throw ComputerError("Application menu must retain the full About name.")
        }
        print("APPLICATION NAME TEST PASSED: menu and app=\(displayName), About retains full name")
    }

    private static func checkTerminalScrollIndicator() throws {
        let terminal = ComputerNativeTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        guard let scroller = terminal.subviews.compactMap({ $0 as? NSScroller }).first else {
            throw ComputerError("Terminal scroll indicator is missing.")
        }
        terminal.feed(text: "One line\r\n")
        terminal.viewWillDraw()
        guard !terminal.canScroll, scroller.alphaValue == 0 else {
            throw ComputerError("Terminal shows a scrollbar with no scrollback.")
        }
        terminal.feed(text: String(repeating: "Scrollback line\r\n", count: 200))
        terminal.viewWillDraw()
        guard terminal.canScroll, scroller.alphaValue == 1 else {
            throw ComputerError("Terminal hides the scrollbar when scrollback is available.")
        }
        print("TERMINAL SCROLLBAR TEST PASSED: hidden without scrollback, visible with scrollback")
    }

    private static func checkToolbarSymbolSizing() throws {
        let reference = NSHostingView(rootView: Label("Edit", systemImage: "slider.horizontal.3").labelStyle(.iconOnly))
        let expected = reference.fittingSize
        for symbol in ["power", "play.fill", "terminal", "desktopcomputer"] {
            for busy in [false, true] {
                let host = NSHostingView(rootView: ComputerToolbarSymbol(systemName: symbol, busy: busy))
                let actual = host.fittingSize
                guard abs(actual.width - expected.width) < 0.5, abs(actual.height - expected.height) < 0.5 else {
                    throw ComputerError("Toolbar symbol differs from the reference label: \(actual), \(expected)")
                }
            }
        }
        print("TOOLBAR SIZING TEST PASSED: all icons and busy states match the reference label's intrinsic dimensions")
    }

    private static func checkAppearanceSheetSizing() async throws {
        // The sidebar uses large controls. A sheet must not inherit their
        // inflated capsule sizing when opened from a sidebar context menu.
        let host = NSHostingView(rootView: ComputerAppearanceSheet(appearance: .constant(.init())).controlSize(.regular))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 650),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(200))
        let regular = host.fittingSize
        host.rootView = ComputerAppearanceSheet(appearance: .constant(.init())).controlSize(.large)
        try await Task.sleep(for: .milliseconds(200))
        let sidebar = host.fittingSize
        guard abs(regular.width - 520) < 1, abs(regular.width - sidebar.width) < 1,
              abs(regular.height - sidebar.height) < 1, regular.height < 700 else {
            throw ComputerError("Appearance sheet sizing changes with its presenter: \(regular), \(sidebar)")
        }
        print("APPEARANCE LAYOUT TEST PASSED: same compact sizing from regular and large-control presenters")
    }

    private final class StopConfirmationFixture: ObservableObject {
        @Published var presented = false
        var confirmations = 0
    }
    private struct StopConfirmationFixtureView: View {
        @ObservedObject var fixture: StopConfirmationFixture
        var body: some View {
            Text("Stop confirmation verification").frame(width: 440, height: 240)
                .computerStopConfirmation(isPresented: $fixture.presented, name: "Test Computer") {
                    fixture.confirmations += 1
                }
        }
    }
    private static func checkStopConfirmation() async throws {
        let fixture = StopConfirmationFixture()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: StopConfirmationFixtureView(fixture: fixture))
        window.orderBack(nil)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet); sheet.orderOut(nil) }
            window.orderOut(nil)
        }
        func button(_ title: String, in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == title { return button }
            return view.subviews.compactMap { button(title, in: $0) }.first
        }
        for title in ["Cancel", "Stop"] {
            fixture.presented = true
            try await Task.sleep(for: .milliseconds(350))
            guard fixture.confirmations == 0, let content = window.attachedSheet?.contentView,
                  let action = button(title, in: content) else {
                throw ComputerError("Stop must wait for an explicit confirmation with Cancel available.")
            }
            action.performClick(nil)
            try await Task.sleep(for: .milliseconds(350))
            guard !fixture.presented, fixture.confirmations == (title == "Stop" ? 1 : 0) else {
                throw ComputerError("Cancel/Stop confirmation behavior is incorrect.")
            }
        }
        print("STOP CONFIRMATION TEST PASSED: requesting Stop does nothing, Cancel preserves it, confirming invokes Stop exactly once")
    }

    private static func checkIconEditor() async throws {
        let host = NSHostingView(rootView: ComputerIconSheet(appearance: .constant(.init()), symbol: "terminal"))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 570),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(300))
        window.setContentSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        guard abs(host.bounds.width - 440) < 1, host.bounds.height < 610 else {
            throw ComputerError("The icon editor no longer has Noodle's compact layout: \(host.bounds)")
        }
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("Noodle-Icon-Layout.png")
                try data.write(to: url)
                print("ICON PREVIEW: \(url.path)")
            }
        }
        print("ICON LAYOUT TEST PASSED: compact 440-point Noodle icon editor")
    }

    private static func checkDesktopToolbarLayout(store: ComputerStore) async throws {
        func terminalSurface(in view: NSView) -> ComputerTerminalSurface? {
            if let terminal = view as? ComputerTerminalSurface { return terminal }
            return view.subviews.compactMap { terminalSurface(in: $0) }.first
        }
        let shell = ComputerSession(ComputerTemplate.shell.makeComputer())
        var appearance = ComputerAppearance()
        appearance.terminalOpacity = 0.5
        shell.computer.appearance = appearance
        shell.terminal = GuestTerminal()
        let host = NSHostingView(rootView: ComputerDetailView(store: store, session: shell))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.titled, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "desktop-layout-test")
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        for size in [NSSize(width: 900, height: 650), NSSize(width: 700, height: 480)] {
            window.setContentSize(size)
            host.rootView = ComputerDetailView(store: store, session: shell)
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            guard let surface = terminalSurface(in: host) else { throw ComputerError("Shell surface is missing.") }
            let frame = surface.convert(surface.bounds, to: nil)
            let usable = window.contentLayoutRect
            guard frame.height > 100, abs(usable.maxY - frame.maxY - 4) < 1 else {
                throw ComputerError("Display overlaps native toolbar: \(frame), usable \(usable)")
            }
            guard abs(frame.minY - 7) < 0.5 else {
                throw ComputerError("Display bottom plus its 1-point clip must match the sidebar's 8-point inset: \(frame)")
            }
            guard abs(usable.maxX - frame.maxX - 8) < 1, abs(frame.minX - usable.minX - 12) < 1 else {
                throw ComputerError("Display must keep an 8-point outer margin and 12-point panel gap: \(frame)")
            }
            guard surface.layer?.backgroundColor?.alpha == 0.5,
                  surface.terminal.backgroundOpacity == 0,
                  surface.terminal.layer?.backgroundColor?.alpha == 0,
                  abs(surface.terminal.frame.minX - 12) < 1,
                  abs(surface.terminal.frame.minY - 12) < 1 else {
                throw ComputerError("Terminal background must be composited exactly once, with its inset: \(surface.terminal.frame)")
            }
            // Collapsing changes only the outer left inset.
            host.rootView = ComputerDetailView(store: store, session: shell, sidebarCollapsed: true)
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            guard let collapsedSurface = terminalSurface(in: host) else { throw ComputerError("Collapsed display is missing.") }
            let collapsed = collapsedSurface.convert(collapsedSurface.bounds, to: nil)
            guard abs(collapsed.minX - usable.minX - 8) < 1,
                  abs(usable.maxX - collapsed.maxX - 8) < 1,
                  abs(collapsed.minY - frame.minY) < 1,
                  abs(collapsed.height - frame.height) < 1 else {
                throw ComputerError("Collapsed sidebar must give the display matching 8-point side insets: \(collapsed)")
            }
        }
        print("DISPLAY LAYOUT TEST PASSED: 8-point collapsed side/outer margins, 7-point bottom margin plus 1-point clip, 12-point expanded panel gap and terminal inset")
    }

    static func checkDesktop() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoodleDesktop-Verification")
        // Always a fresh computer: a kept one would run the image from an earlier attempt.
        try? FileManager.default.removeItem(at: root)
        let store = try ComputerStore(root: root)
        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                print("DESKTOP: \(store.creationStatus ?? "starting") \(store.creationDetail ?? "")")
                try? await Task.sleep(for: .seconds(5))
            }
        }
        defer { monitor.cancel() }
        let computer = ComputerTemplate.desktop.makeComputer(name: "Desktop Verification")
        let created = store.sessions.isEmpty ? await store.create(computer, source: nil) : true
        guard created, let session = store.selected else {
            throw ComputerError(store.error ?? "Desktop creation failed.")
        }
        await store.start(session)
        guard session.phase == .running, let display = session.display, display.machine != nil else {
            throw ComputerError("Desktop startup failed: \(session.console)")
        }
        func guest(_ command: String) async -> String {
            session.console = ""
            await store.execute(command, in: session)
            return session.console
        }
        func fail(_ message: String) async -> ComputerError {
            await store.stop(session, force: true)
            return ComputerError(message)
        }
        let processes = await guest("for attempt in 1 2 3 4 5 6 7 8 9 10; do if pgrep -x Xorg && pgrep -x openbox && pgrep -x desktop-surface; then exit 0; fi; sleep 1; done; exit 1")
        guard processes.contains("[Exit 0]") else { throw await fail("Desktop processes did not start: \(processes)") }
        // Let the session's own windows open first, so none of them takes focus from a fixture.
        _ = await guest("for attempt in $(seq 1 60); do xdotool search --onlyvisible --class chromium >/dev/null 2>&1 && break; sleep 0.5; done; sleep 3")
        // The whole library window, as people use it: nothing in it may cover the display.
        store.selection = session.id
        let host = NSHostingView(rootView: ComputerLibraryView(store: store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 900),
                              styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "Desktop Verification"
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "desktop-verification")
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        func machineView(in view: NSView) -> VZVirtualMachineView? {
            if let machine = view as? VZVirtualMachineView { return machine }
            return view.subviews.compactMap { machineView(in: $0) }.first
        }
        guard let view = machineView(in: host) else { throw await fail("The desktop shows no native display.") }
        guard !view.automaticallyReconfiguresDisplay else { throw await fail("A new desktop must keep its own resolution.") }

        // Agents and remote viewers: the guest serves frames and takes input.
        let frame: CGImage, size: CGSize
        do { (frame, size) = try await display.surface.frame() } catch {
            let logs = await guest("tail -20 /var/log/desktop/surface.log; tail -5 /var/log/desktop/Xorg.log; pgrep -a desktop-surface")
            throw await fail("The desktop did not serve a frame: \(error.localizedDescription)\n\(logs)")
        }
        guard frame.width == 1920, frame.height == 1200, size == CGSize(width: 1920, height: 1200) else {
            throw await fail("The desktop frame is \(frame.width)x\(frame.height), not its fixed 1920x1200.")
        }
        // The session tiles and stacks its own windows, so find the fixture where it
        // actually is and bring it to the top; clicking it is what gives it focus.
        func openFixture(_ title: String) async throws -> CGPoint {
            let geometry = await guest(#"""
                rm -f /tmp/noodle-typed
                setsid xterm -title '\#(title)' -e sh -c 'read line; printf "%s" "$line" > /tmp/noodle-typed' </dev/null >/tmp/noodle-xterm.log 2>&1 &
                for attempt in $(seq 1 20); do
                    window=$(xdotool search --onlyvisible --name '^\#(title)$' 2>/dev/null | head -n 1)
                    [ -n "$window" ] && break
                    sleep 0.5
                done
                [ -n "$window" ] || { cat /tmp/noodle-xterm.log; wmctrl -l; exit 1; }
                xdotool windowraise "$window"
                sleep 0.5
                xdotool getwindowgeometry --shell "$window"
                """#)
            let fields = Dictionary(geometry.split(whereSeparator: \.isNewline).compactMap { line -> (String, Double)? in
                let parts = line.split(separator: "=")
                guard parts.count == 2, let value = Double(parts[1]) else { return nil }
                return (String(parts[0]), value)
            }, uniquingKeysWith: { first, _ in first })
            guard let x = fields["X"], let y = fields["Y"], let width = fields["WIDTH"], let height = fields["HEIGHT"] else {
                throw await fail("The \(title) window did not open: \(geometry)")
            }
            return CGPoint(x: x + width / 2, y: y + height / 2)
        }
        func click(_ point: CGPoint) async throws {
            for phase in [SurfaceInput.Phase.move, .down, .up] {
                try await display.surface.send(.pointer(phase, x: point.x, y: point.y, clickCount: 1))
            }
            try await Task.sleep(for: .milliseconds(300))
        }
        try await click(try await openFixture("Input Verification"))
        try await display.surface.send(.text("remote viewer"))
        try await display.surface.send(.key(.enter))
        let remote = await guest("for attempt in 1 2 3 4 5 6 7 8 9 10; do [ -s /tmp/noodle-typed ] && break; sleep 0.5; done; cat /tmp/noodle-typed")
        guard remote.contains("remote viewer") else { throw await fail("Input from a remote viewer did not reach the desktop: \(remote)") }

        // A person at the Mac: keys go through the view's virtual keyboard.
        try await click(try await openFixture("Keyboard Verification"))
        window.makeFirstResponder(view)
        for (character, code) in [("m", UInt16(46)), ("a", 0), ("c", 8), ("\r", 36)] {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                window.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: character,
                    charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)!)
            }
        }
        let local = await guest("for attempt in 1 2 3 4 5 6 7 8 9 10; do [ -s /tmp/noodle-typed ] && break; sleep 0.5; done; cat /tmp/noodle-typed")
        guard local.contains("mac") else { throw await fail("Keys typed into the desktop view did not arrive: \(local)") }

        // A person's pointer: the Mac view's own mouse events, where nothing may cover the view.
        host.layoutSubtreeIfNeeded()
        func windowPoint(guestX: CGFloat, guestY: CGFloat) -> NSPoint {
            // The view fits the 1920x1200 screen inside its bounds, keeping its shape.
            let scale = min(view.bounds.width / 1920, view.bounds.height / 1200)
            let x = (view.bounds.width - 1920 * scale) / 2 + guestX * scale
            let y = (view.bounds.height - 1200 * scale) / 2 + (1200 - guestY) * scale
            return view.convert(NSPoint(x: view.isFlipped ? x : x, y: view.isFlipped ? view.bounds.height - y : y), to: nil)
        }
        func mouse(_ type: NSEvent.EventType, _ location: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: type == .mouseMoved ? 0 : 1, pressure: type == .leftMouseDown ? 1 : 0)!
        }
        let centre = windowPoint(guestX: 960, guestY: 600)
        let hit = window.contentView?.superview?.hitTest(centre)
        guard hit === view || hit?.isDescendant(of: view) == true else {
            throw await fail("A click on the desktop lands on \(hit.map { String(describing: type(of: $0)) } ?? "nothing"), not the display.")
        }
        view.mouseMoved(with: mouse(.mouseMoved, centre))
        try await Task.sleep(for: .milliseconds(500))
        let moved = await guest("xdotool getmouselocation --shell")
        let target = try await openFixture("Pointer Verification")
        let point = windowPoint(guestX: target.x, guestY: target.y)
        view.mouseMoved(with: mouse(.mouseMoved, point))
        view.mouseDown(with: mouse(.leftMouseDown, point))
        view.mouseUp(with: mouse(.leftMouseUp, point))
        try await Task.sleep(for: .milliseconds(500))
        let focused = await guest("xdotool getwindowfocus getwindowname; xdotool getmouselocation --shell")
        guard focused.contains("Pointer Verification") else {
            let inputs = await guest("grep -iE 'evdev|input|pointer|digitizer' /var/log/desktop/Xorg.log | tail -15")
            throw await fail("A click through the desktop view did not reach the guest.\nCentre: \(moved)\nAfter click at \(target): \(focused)\n\(inputs)")
        }
        // The same through the system's event queue, as a real mouse arrives.
        print("PASS: native display, guest frames, remote and local keyboard and pointer input")

        // ⌘V and ⌘C through the view, with a private pasteboard: the person's own clipboard is never touched.
        guard let desktopView = view as? DesktopMachineView else { throw await fail("The desktop view does not handle copy and paste.") }
        let pasteboard = NSPasteboard(name: .init("NoodleDesktopVerification-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        desktopView.pasteboard = pasteboard
        // ⌘C and ⌘V are the Edit menu's items: send what each item sends, down the window's
        // responder chain, as the menu does. Posting keys would need this app to be frontmost.
        func menu(_ key: String) async throws {
            guard let item = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items)
                    .first(where: { $0.keyEquivalent == key && $0.keyEquivalentModifierMask == .command }),
                  let action = item.action else { throw await fail("The app has no ⌘\(key.uppercased()) menu item.") }
            window.makeFirstResponder(desktopView)
            guard window.firstResponder?.tryToPerform(action, with: item) == true else {
                throw await fail("\(item.title) did not reach the desktop.")
            }
        }
        try await click(try await openFixture("Paste Verification"))
        pasteboard.clearContents()
        pasteboard.setString("pasted from the mac\n", forType: .string)
        try await menu("v")
        let pasted = await guest("for attempt in 1 2 3 4 5 6 7 8 9 10; do [ -s /tmp/noodle-typed ] && break; sleep 0.5; done; cat /tmp/noodle-typed")
        guard pasted.contains("pasted from the mac") else { throw await fail("⌘V did not paste the Mac clipboard: \(pasted)") }
        try await click(try await openFixture("Copy Verification"))
        _ = await guest("printf 'copied in the guest' | xclip -selection primary -in")
        pasteboard.clearContents()
        try await menu("c")
        var copied: String?
        for _ in 0..<20 where copied == nil {
            try await Task.sleep(for: .milliseconds(250))
            copied = pasteboard.string(forType: .string)
        }
        guard copied == "copied in the guest" else { throw await fail("⌘C did not copy the terminal's selection: \(copied ?? "nothing")") }
        print("PASS: ⌘V pastes the Mac clipboard into the desktop and ⌘C copies back, only when pressed")

        // The desktop's own terminal, which its menus and welcome open, draws with OpenGL.
        let kitty = await guest(#"""
            setsid kitty --title 'Kitty Verification' </dev/null >/tmp/noodle-kitty.log 2>&1 &
            for attempt in $(seq 1 20); do
                xdotool search --onlyvisible --name '^Kitty Verification$' >/dev/null 2>&1 && exit 0
                sleep 0.5
            done
            cat /tmp/noodle-kitty.log; exit 1
            """#)
        guard kitty.contains("[Exit 0]") else { throw await fail("The desktop's terminal did not open: \(kitty)") }
        print("PASS: the desktop's own terminal opens")

        // Resize with window: turning it on makes the guest take the view's size at once.
        store.rename(session, name: session.computer.name, resizesDesktop: true)
        host.layoutSubtreeIfNeeded()
        var resized = false
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(500))
            if let (next, _) = try? await display.surface.frame(), next.width != 1920 || next.height != 1200 { resized = true; break }
        }
        guard view.automaticallyReconfiguresDisplay, resized else {
            let state = await guest("cat /sys/class/drm/card*-*/modes | head -3; xrandr | head -3; tail -5 /var/log/desktop/resize.log")
            throw await fail("The desktop did not follow its window's size (view resizes: \(view.automaticallyReconfiguresDisplay), view \(view.bounds.size)):\n\(state)")
        }
        // Turning it off returns the desktop to its own resolution straight away.
        store.rename(session, name: session.computer.name, resizesDesktop: false)
        var restored = false
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(500))
            if let (next, _) = try? await display.surface.frame(), next.width == 1920, next.height == 1200 { restored = true; break }
        }
        guard restored else { throw await fail("Turning off Resize desktop with window did not restore 1920x1200.") }
        // Changing the setting while the desktop is hidden applies when it shows again.
        store.rename(session, name: session.computer.name, resizesDesktop: true)
        await store.toggleTerminal(session)
        store.rename(session, name: session.computer.name, resizesDesktop: false)
        await store.toggleTerminal(session)
        host.layoutSubtreeIfNeeded()
        var settled = false
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(500))
            if let (next, _) = try? await display.surface.frame(), next.width == 1920, next.height == 1200 { settled = true; break }
        }
        guard settled else { throw await fail("A setting changed while the desktop was hidden did not apply.") }
        print("PASS: desktop resizes with its window when chosen, and returns to its own resolution when not, across tabs")

        // The recovery terminal keeps working while the display server is paused.
        let paused = await guest("sudo -n pkill -STOP -x Xorg && ps -o stat= -p $(pgrep -x Xorg) | grep -q T")
        guard paused.contains("[Exit 0]") else { throw await fail("Could not pause the test desktop display server.") }
        await store.toggleTerminal(session)
        guard session.showingTerminal, let terminal = session.terminal else { throw await fail("Desktop recovery terminal did not open.") }
        host.layoutSubtreeIfNeeded()
        guard machineView(in: host) == nil else { throw await fail("The hidden desktop view stays under the terminal and sets its pointer.") }
        terminal.io.send(Data("export NOODLE_RECOVERY=alive; printf '\\n__RECOVERY_%s__\\n' READY\r".utf8))
        func terminalScreen() -> String {
            String(decoding: terminal.view.getTerminal().getBufferAsData(), as: UTF8.self)
        }
        for _ in 0..<100 {
            if terminalScreen().contains("__RECOVERY_READY__") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard terminalScreen().contains("__RECOVERY_READY__") else { throw await fail("Terminal stopped responding while the desktop was paused.") }
        await store.toggleTerminal(session)
        guard !session.showingTerminal else { throw await fail("Show Desktop did not switch back.") }
        await store.toggleTerminal(session)
        guard session.terminal === terminal else { throw await fail("Switching replaced the shell session.") }
        terminal.io.send(Data("printf '\\n__PRESERVED_%s__\\n' \"$NOODLE_RECOVERY\"\r".utf8))
        for _ in 0..<100 {
            if terminalScreen().contains("__PRESERVED_alive__") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard terminalScreen().contains("__PRESERVED_alive__") else { throw await fail("Switching lost the shell environment.") }
        _ = await guest("sudo -n pkill -CONT -x Xorg")
        await store.toggleTerminal(session)
        host.layoutSubtreeIfNeeded()
        guard machineView(in: host)?.virtualMachine === display.machine, session.display === display else {
            throw await fail("Switching back did not show the same computer's display.")
        }
        // The pointer must still reach the guest after the display was hidden and shown again.
        guard let shown = machineView(in: host) else { throw await fail("The desktop view is missing after switching back.") }
        let before = await guest("xdotool getmouselocation --shell")
        let corner = shown.convert(NSPoint(x: shown.bounds.width * 0.2, y: shown.bounds.height * 0.3), to: nil)
        shown.mouseMoved(with: mouse(.mouseMoved, corner))
        try await Task.sleep(for: .milliseconds(500))
        let after = await guest("xdotool getmouselocation --shell")
        guard after != before else {
            throw await fail("After switching back, the pointer no longer reaches the guest.\nBefore: \(before)\nAfter: \(after)")
        }
        print("RECOVERY TERMINAL TEST PASSED: shell works with paused desktop; switching preserves its session and the pointer")

        // Watching from Noodle Hub with no window open: a streamer set up as the provider sets
        // one up for a desktop, with a viewer on the other end of its socket.
        window.contentView = nil
        window.orderOut(nil)
        let streamer = SurfaceStreamer(capture: { try await display.surface.frame() },
                                       apply: { try await display.surface.send($0) })
        defer { streamer.stop() }
        var sockets: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else { throw await fail("No socket for the live view.") }
        streamer.attach(SurfaceSocket(fd: sockets[0]))
        let viewer = SurfaceSocket(fd: sockets[1])
        defer { viewer.close() }
        viewer.send(SurfaceControl.view(width: 1920, height: 1200).encoded)
        let video = await withTaskGroup(of: [SurfacePacket]?.self) { group -> [SurfacePacket]? in
            group.addTask {
                for await frame in viewer.frames {
                    if let packets = SurfacePacket.decode(frame), !packets.isEmpty { return packets }
                }
                return nil
            }
            group.addTask { try? await Task.sleep(for: .seconds(20)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let first = video?.first, first.keyFrame, first.width > 0, first.height > 0 else {
            throw await fail("A live view with no window open received no video.")
        }
        let streamed = try await openFixture("Stream Verification")
        for phase in [SurfaceInput.Phase.move, .down, .up] {
            viewer.send(SurfaceControl.input(.pointer(phase, x: streamed.x, y: streamed.y, clickCount: 1)).encoded)
        }
        try await Task.sleep(for: .milliseconds(300))
        viewer.send(SurfaceControl.input(.text("watched from the hub")).encoded)
        viewer.send(SurfaceControl.input(.key(.enter)).encoded)
        let watched = await guest("for attempt in 1 2 3 4 5 6 7 8 9 10; do [ -s /tmp/noodle-typed ] && break; sleep 0.5; done; cat /tmp/noodle-typed")
        guard watched.contains("watched from the hub") else { throw await fail("Input from a live view did not reach the desktop: \(watched)") }
        print("PASS: live view with no window open: \(first.width)x\(first.height) video out, pointer and typing in")
        await store.stop(session, force: true)
        print("DESKTOP TEST PASSED: native display on the virtual GPU, Xorg/Openbox, guest frames and input, resize with window")
        try? FileManager.default.removeItem(at: root)
    }

    static func checkDownloadProgressAndCancellation() async throws {
        setbuf(stdout, nil)
        var received: TransferProgress?
        let reporter = DownloadProgressReporter { update in
            Task { @MainActor in received = update }
        }
        let request = URLRequest(
            url: URL(
                string: "https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/aarch64/alpine-virt-3.23.5-aarch64.iso")!)
        let task = Task { try await reporter.download(for: request) }
        for _ in 0..<600 {
            if let received, received.received > 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        task.cancel()
        do {
            let (file, _) = try await task.value
            try? FileManager.default.removeItem(at: file)
            throw ComputerError("The download finished before cancellation could be tested.")
        } catch let error as URLError where error.code == .cancelled {
            guard let received, received.received > 0, received.fraction != nil else {
                throw ComputerError("The download did not report byte progress.")
            }
            print(
                "DOWNLOAD TEST PASSED: live byte/total progress received, task cancellation stopped URLSession download"
            )
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NoodleComputer-Cancel-Test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try ComputerStore(root: root)
        let creation = Task { await store.create(Computer(name: "Cancel Test", kind: .macOS), source: nil) }
        creation.cancel()
        let result = await creation.value
        guard !result, store.creationWasCancelled, store.creationStatus == nil, try store.library.load().isEmpty else {
            throw ComputerError("Cancelled creation left published computer state.")
        }
        print("CREATION CANCELLATION TEST PASSED: no computer published; progress state cleared")

        let small = DownloadProgressReporter { _ in }
        let (file, response) = try await small.download(for: URLRequest(url: request.url!.appendingPathExtension("sha256")))
        defer { try? FileManager.default.removeItem(at: file) }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              try String(contentsOf: file, encoding: .utf8).contains("alpine-virt") else {
            throw ComputerError("Completed download did not retain its file.")
        }
        print("DOWNLOAD COMPLETION TEST PASSED: completed file remains readable for cache adoption")
    }

    static func linuxBootFixture() async throws -> ComputerStore {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NoodleComputer-Linux-Test-\(UUID().uuidString)")
        let store = try ComputerStore(root: root)
        let source = URL(
            string: "https://dl-cdn.alpinelinux.org/alpine/v3.23/releases/aarch64/alpine-virt-3.23.5-aarch64.iso")!
        let (download, response) = try await URLSession.shared.download(from: source)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ComputerError("Linux test image download failed.")
        }
        defer { try? FileManager.default.removeItem(at: download) }
        let (checksum, _) = try await URLSession.shared.data(from: source.appendingPathExtension("sha256"))
        let expected = String(decoding: checksum, as: UTF8.self).split(separator: " ").first.map(String.init)
        let actual = SHA256.hash(data: try Data(contentsOf: download, options: .mappedIfSafe)).map {
            String(format: "%02x", $0)
        }.joined()
        guard actual == expected else { throw ComputerError("Linux test installer checksum mismatch.") }
        let computer = Computer(name: "Linux Boot Test", kind: .linux, cpuCount: 2, memoryGiB: 2, diskGiB: 4)
        guard await store.create(computer, source: download), let session = store.selected else {
            throw ComputerError(store.error ?? "Linux test creation failed.")
        }
        await store.start(session)
        guard session.phase == .running else { throw ComputerError("Linux VM did not start.") }
        print("LINUX BOOT FIXTURE: VM running; inspect the guest display. Temporary library: \(root.path)")
        return store
    }

    static func checkMacConfiguration() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NoodleComputer-Mac-Test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = try await VZMacOSRestoreImage.latestSupported
        guard let requirements = image.mostFeaturefulSupportedConfiguration else {
            throw ComputerError("No macOS restore image supports this Mac.")
        }
        let computer = Computer(
            name: "Mac Configuration Test", kind: .macOS,
            cpuCount: max(2, requirements.minimumSupportedCPUCount),
            memoryGiB: max(4, Int((requirements.minimumSupportedMemorySize + 1_073_741_823) / 1_073_741_824)))
        try requirements.hardwareModel.dataRepresentation.write(to: root.appendingPathComponent("HardwareModel"))
        try VZMacMachineIdentifier().dataRepresentation.write(to: root.appendingPathComponent("MachineIdentifier"))
        _ = try VZMacAuxiliaryStorage(
            creatingStorageAt: root.appendingPathComponent("AuxiliaryStorage"),
            hardwareModel: requirements.hardwareModel, options: [])
        let disk = root.appendingPathComponent("Disk.img")
        guard FileManager.default.createFile(atPath: disk.path, contents: nil) else {
            throw ComputerError("Cannot create test disk.")
        }
        let file = try FileHandle(forWritingTo: disk)
        try file.truncate(atOffset: 64 * 1_073_741_824)
        try file.close()
        _ = try VirtualComputer(computer: computer, directory: root, bootInstaller: false)
        print(
            "MAC CONFIGURATION TEST PASSED: Apple restore metadata, hardware model, auxiliary storage, disk, graphics, input, audio, NAT, and VZ validation"
        )
    }

    private static func checkTerminalReconnection(store: ComputerStore, session: ComputerSession) async throws {
        guard let terminal = session.terminal, let runtime = session.container else {
            throw ComputerError("Missing terminal for exit recovery test.")
        }
        let display = session.display
        for (index, command) in [Data("exit\r".utf8), Data([4]), Data("kill -KILL $$\r".utf8)].enumerated() {
            let previousIO = terminal.io
            terminal.io.send(command)
            for _ in 0..<100 {
                if terminal.io !== previousIO { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard terminal.io !== previousIO else { throw ComputerError("Shell exit did not reconnect (case \(index)).") }
            terminal.io.send(Data("printf '\\n__REOPEN_%s__\\n' \(index)\r".utf8))
            var ready = false
            for _ in 0..<100 {
                let screen = String(decoding: terminal.view.getTerminal().getBufferAsData(), as: UTF8.self)
                if screen.contains("__REOPEN_\(index)__") { ready = true; break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard ready, session.terminal === terminal, session.container === runtime,
                  session.phase == .running, session.display === display else {
                throw ComputerError("Terminal recovery failed or replaced the computer/desktop (case \(index)).")
            }
        }
        print("TERMINAL RECONNECTION TEST PASSED: exit, Ctrl-D, killed shell; same terminal, computer and display")
    }

    static func run(networkEnabled: Bool = true) async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "NoodleComputer-Test-\(UUID().uuidString)")
        let store = try ComputerStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let hostHome = URL(fileURLWithPath: String(cString: getpwuid(getuid())!.pointee.pw_dir))
        let deniedProbe = hostHome.appendingPathComponent("NoodleComputer-SandboxProbe-\(UUID().uuidString)")
        var escapedSandbox = false
        do {
            try Data("sandbox probe".utf8).write(to: deniedProbe)
            escapedSandbox = true
            try? FileManager.default.removeItem(at: deniedProbe)
        } catch { /* Expected: no write access to the user's actual home. */  }
        guard !escapedSandbox else { throw ComputerError("The signed app can unexpectedly write outside its sandbox.") }
        print("COMPUTER SELF-TEST: host filesystem containment passed")
        var computer = ComputerTemplate.shell.makeComputer(name: "Integration Test")
        computer.networkEnabled = networkEnabled
        print("COMPUTER SELF-TEST: create Alpine workspace")
        guard await store.create(computer, source: nil), let session = store.selected else {
            throw ComputerError(store.error ?? "Creation failed.")
        }
        await store.start(session)
        guard session.phase == .running else { throw ComputerError("Boot failed: \(session.console)") }
        print("COMPUTER SELF-TEST: boot passed (networking \(networkEnabled ? "enabled; DHCP passed" : "disabled"))")
        guard let terminal = session.terminal, let runtime = session.container else {
            throw ComputerError("The headless computer did not open its terminal.")
        }
        func screen() -> String {
            String(decoding: terminal.view.getTerminal().getBufferAsData(), as: UTF8.self)
        }
        try await runtime.resizeTerminal(columns: 100, rows: 32)
        terminal.io.send(Data("printf '\\n__PTY_%s__\\n' READY; stty size\r".utf8))
        for _ in 0..<100 {
            if screen().contains("__PTY_READY__"), screen().contains("32 100") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard screen().contains("__PTY_READY__"), screen().contains("32 100") else {
            await store.stop(session, force: true)
            throw ComputerError("Interactive terminal input/output or resize failed: \(screen())")
        }
        terminal.io.send(Data("sleep 30\r".utf8))
        try await Task.sleep(for: .milliseconds(200))
        terminal.io.send(Data([3]))
        terminal.io.send(Data("printf '\\n__INTERRUPT_%s__\\n' OK\r".utf8))
        for _ in 0..<100 {
            if screen().contains("__INTERRUPT_OK__") { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard screen().contains("__INTERRUPT_OK__") else {
            await store.stop(session, force: true)
            throw ComputerError("The guest terminal did not handle Control-C.")
        }
        print("TERMINAL TEST PASSED: guest PTY input/output, window resize, Control-C and native terminal rendering")
        do { try await checkTerminalReconnection(store: store, session: session) }
        catch { await store.stop(session, force: true); throw error }
        let packageCheck = networkEnabled ? " && if command -v sudo >/dev/null; then sudo apk add --no-cache jq; else apk add --no-cache jq; fi && jq --version" : ""
        await store.execute("uname -m && printf noodle-persistence > /workspace/sentinel" + packageCheck, in: session)
        guard session.console.contains("aarch64"), session.console.contains("[Exit 0]"),
            !networkEnabled || session.console.contains("jq-")
        else {
            await store.stop(session, force: true)
            throw ComputerError("Guest package installation failed: \(session.console)")
        }
        print("COMPUTER SELF-TEST: guest execution passed\(networkEnabled ? "; package installation passed" : "")")
        terminal.io.send(Data("exit\r".utf8))
        await store.stop(session, force: true)
        guard session.phase == .stopped else { throw ComputerError("Stop failed.") }
        try await Task.sleep(for: .milliseconds(600))
        guard session.phase == .stopped, session.terminal == nil, session.container == nil else {
            throw ComputerError("Terminal recovery restarted a stopped computer.")
        }
        let records = try store.library.load()
        guard records.count == 1, records[0].id == computer.id else {
            throw ComputerError("Persistence reload failed.")
        }
        await store.start(session)
        guard session.phase == .running else { throw ComputerError("Restart failed: \(session.console)") }
        session.console = ""
        await store.execute("cat /workspace/sentinel" + (networkEnabled ? " && jq --version" : ""), in: session)
        guard session.console.contains("noodle-persistence"), !networkEnabled || session.console.contains("jq-"),
            session.console.contains("[Exit 0]")
        else {
            await store.stop(session, force: true)
            throw ComputerError("Guest disk did not persist: \(session.console)")
        }
        await store.stop(session, force: true)
        guard session.phase == .stopped else { throw ComputerError("Final stop failed.") }
        // Creation/configuration of an EFI machine requires no installed guest OS.
        let linux = Computer(name: "EFI Configuration", kind: .linux, cpuCount: 2, memoryGiB: 2, diskGiB: 4)
        let iso = root.appendingPathComponent("fixture.iso")
        try Data(repeating: 0, count: 4096).write(to: iso)
        guard await store.create(linux, source: iso) else {
            throw ComputerError(store.error ?? "EFI configuration failed.")
        }
        print(
            "COMPUTER SELF-TEST PASSED: boot, guest execution, restart persistence, library reload, EFI configuration; network tests \(networkEnabled ? "passed" : "not requested")"
        )
    }
    #endif
}
