import AppKit
import ComputerCore
import ComputerBridge
import CryptoKit
import Foundation
import Virtualization
import SwiftUI
import WebKit

/// Opt-in signed-app integration fixture. Never opens the user's computer library.
@MainActor enum ComputerSmokeTest {
    static func checkProvider() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoodleProvider-Test-\(UUID().uuidString)")
        let store = try ComputerStore(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshotTest = CommandLine.arguments.contains("--provider-snapshot-test")
        var computer = (snapshotTest ? ComputerTemplate.desktop : .shell).makeComputer(name: "Isolated Provider Test")
        computer.networkEnabled = snapshotTest
        if CommandLine.arguments.contains("--provider-web-test") {
            computer.customImage = true; computer.webPort = 8080; computer.networkEnabled = true
        }
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
                guard session.phase == .running, let browser = session.browser else {
                    throw ComputerError("The isolated desktop did not start.")
                }
                // Exercise real remote pixels, not just a synthetic HTML canvas.
                guard let runtime = session.container else { throw ComputerError("Missing fixture runtime") }
                let fixture = try await runtime.execute(#"""
                    command -v xterm && for n in 1 2 3 4 5 6 7 8 9 10; do pgrep -x openbox >/dev/null && break; sleep 1; done
                    DISPLAY=:1 XAUTHORITY=/run/launcher-desktop/Xauthority xterm -geometry 70x20+40+60 -title 'Preview Verification' -e /bin/sh -c 'printf "Native desktop preview\nNo grey browser bands\nCorrect text proportions\n"; sleep 180' >/tmp/noodle-preview-xterm.log 2>&1 &
                    """#)
                print("SNAPSHOT FIXTURE: \(fixture)")
                var connected = false
                for _ in 0..<60 {
                    if (try? await browser.view.evaluateJavaScript("document.documentElement.classList.contains('noVNC_connected')")) as? Bool == true {
                        connected = true; break
                    }
                    try await Task.sleep(for: .seconds(1))
                }
                guard connected else { throw ComputerError("Real desktop canvas never connected") }
                try await Task.sleep(for: .seconds(3))
                let state = try await browser.view.evaluateJavaScript("JSON.stringify([...document.querySelectorAll('canvas')].map(c=>({pixels:[c.width,c.height],rect:[c.getBoundingClientRect().width,c.getBoundingClientRect().height]})))")
                print("REAL CANVAS: \(String(describing: state))")
                let began = ProcessInfo.processInfo.systemUptime
                var nativeSize: NSSize?
                var nativeCorner: NSColor?
                if let image = await ComputerPreviewSnapshot.capture(browser.view, desktop: true) {
                    guard let bitmap = NSBitmapImageRep(data: image) else { throw ComputerError("Invalid native snapshot") }
                    nativeSize = NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh)
                    nativeCorner = bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB)
                    let ext = image.starts(with: [137, 80, 78, 71]) ? "png" : "jpg"
                    let output = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-desktop-snapshot-test.\(ext)")
                    try image.write(to: output)
                    print("PASS: real background desktop snapshot saved to \(output.path)")
                } else {
                    throw ComputerError("Ready real desktop must produce a snapshot, not a fallback")
                }
                guard ProcessInfo.processInfo.systemUptime - began < 9 else {
                    throw ComputerError("Desktop snapshot exceeded its deadline.")
                }
                // Reproduce the reported CSS letterbox/stretch without changing guest pixels.
                _ = try await browser.view.evaluateJavaScript("document.body.style.background='#272727';for(const c of document.querySelectorAll('canvas')){c.style.setProperty('margin-top','140px','important');c.style.setProperty('width','500px','important');c.style.setProperty('height','250px','important');}")
                guard let cropped = await ComputerPreviewSnapshot.capture(browser.view, desktop: true) else {
                    throw ComputerError("Letterboxed real desktop did not produce a snapshot")
                }
                guard let bitmap = NSBitmapImageRep(data: cropped),
                      NSSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh) == nativeSize,
                      let corner = bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB),
                      let nativeCorner,
                      abs(corner.redComponent - nativeCorner.redComponent) < 0.02,
                      abs(corner.greenComponent - nativeCorner.greenComponent) < 0.02,
                      abs(corner.blueComponent - nativeCorner.blueComponent) < 0.02 else {
                    throw ComputerError("Native framebuffer dimensions changed or grey browser margin entered the snapshot")
                }
                try cropped.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("noodle-real-letterbox-result.png"))
                print("PASS: real remote canvas captured after forced letterboxing and CSS stretching")
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
        let session = ComputerSession(ComputerTemplate.desktop.makeComputer())
        session.desktop = DesktopConnection(url: URL(string: "https://127.0.0.1:1/")!)
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
        session.terminal = GuestTerminal()
        for size in [NSSize(width: 1000, height: 650), NSSize(width: 1001, height: 651)] {
            window.setContentSize(size)
            for terminal in [false, true] {
                session.showingTerminal = terminal
                try await Task.sleep(for: .milliseconds(400))
                host.layoutSubtreeIfNeeded()
                guard let glass = find(in: host, matching: { String(describing: type(of: $0)).contains("ConcentricGlassEffectView") }),
                      let display = find(in: host, matching: { terminal ? $0 is ComputerTerminalSurface : $0 is WKWebView }) else {
                    throw ComputerError("Native sidebar or display missing from full-library fixture")
                }
                let sidebarFrame = glass.convert(glass.bounds, to: nil)
                let displayFrame = display.convert(display.bounds, to: nil)
                guard abs(sidebarFrame.minY - displayFrame.minY) < 0.01 else {
                    throw ComputerError("Sidebar/display bottom bounds differ: \(sidebarFrame), \(displayFrame)")
                }
                print("PASS: full-library \(terminal ? "terminal" : "web") bottom matches native glass at \(displayFrame.minY), size \(size)")
            }
        }
        session.showingTerminal = false
        let browser = session.browser!
        browser.view.loadHTMLString("""
          <html><head><style>html,body{margin:0;width:100%;height:100%}
          #noVNC_container{display:flex;width:100%;height:100%;background:black}</style></head>
          <body><div id="noVNC_container"><canvas style="margin:auto" width="100" height="100"></canvas></div></body></html>
          """, baseURL: browser.connection.url)
        var anchored = false
        for _ in 0..<50 {
            if (try? await browser.view.evaluateJavaScript("""
              (() => {const c=document.querySelector('canvas');if(!c)return false;
              const r=c.getBoundingClientRect();return r.top===0 && r.left===0;})()
              """)) as? Bool == true { anchored = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard anchored else { throw ComputerError("Remote canvas was centered instead of anchored at the viewport origin") }
        print("PASS: embedded desktop canvas has no top/left auto-margin")
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

    static func checkCustomContainer() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoodleCustom-Verification")
        let store = try ComputerStore(root: root)
        let monitor = Task { @MainActor in
            while !Task.isCancelled {
                print("CUSTOM: \(store.creationStatus ?? "starting/testing") \(store.creationDetail ?? "")")
                try? await Task.sleep(for: .seconds(5))
            }
        }
        defer { monitor.cancel() }
        var computer = Computer(name: "Custom Web Test", kind: .container, cpuCount: 2,
            memoryGiB: 1, diskGiB: 8, imageReference: "docker.io/library/nginx:alpine", customImage: true, webPort: 80)
        var appearance = ComputerAppearance()
        appearance.backgroundPreset = "ocean"
        appearance.iconSymbol = "globe"
        appearance.iconColour = 1
        appearance.terminalOpacity = 0
        appearance.terminalForeground = "33FF99"
        computer.appearance = appearance
        let created = store.sessions.isEmpty ? await store.create(computer, source: nil) : true
        guard created, let session = store.selected else { throw ComputerError(store.error ?? "Custom creation failed.") }
        await store.start(session)
        guard session.phase == .running, session.desktop?.url.scheme == "http" else {
            throw ComputerError("Custom image did not start: \(session.console)")
        }
        let host = NSHostingView(rootView: ComputerLibraryView(store: store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "custom-verification")
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        func webView(in view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.compactMap { webView(in: $0) }.first
        }
        var rendered = false
        for _ in 0..<30 {
            try await Task.sleep(for: .seconds(1))
            if let web = webView(in: host),
               let text = try? await web.evaluateJavaScript("document.body.innerText") as? String,
               text.contains("Welcome to nginx!") { rendered = true; break }
        }
        guard rendered else {
            if let web = webView(in: host) {
                print("CUSTOM WEB: url=\(web.url?.absoluteString ?? "nil") loading=\(web.isLoading)")
                print("CUSTOM WEB HTML: \((try? await web.evaluateJavaScript("document.documentElement.outerHTML")) ?? "unavailable")")
            }
            await store.execute("ps aux; wget -qO- http://127.0.0.1:80/", in: session)
            print("CUSTOM GUEST: \(session.console)")
            await store.stop(session, force: true)
            throw ComputerError("Custom HTTP port did not render its nginx page.")
        }
        await store.toggleTerminal(session)
        guard let terminal = session.terminal, session.showingTerminal else {
            throw ComputerError("Custom web image recovery terminal did not open.")
        }
        terminal.io.send(Data("printf '\\n__CUSTOM_%s__\\n' READY\r".utf8))
        try await Task.sleep(for: .seconds(1))
        host.layoutSubtreeIfNeeded()
        let screen = String(decoding: terminal.view.getTerminal().getBufferAsData(), as: UTF8.self)
        guard screen.contains("__CUSTOM_READY__"), terminal.view.backgroundOpacity == 0 else {
            throw ComputerError("Custom terminal or transparent appearance failed.")
        }
        do { try await checkTerminalReconnection(store: store, session: session) }
        catch { await store.stop(session, force: true); throw error }
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(
                to: FileManager.default.temporaryDirectory.appendingPathComponent("NoodleCustom-Appearance.png"))
        }
        await store.stop(session, force: true)
        guard session.phase == .stopped else { throw ComputerError("Custom computer did not stop.") }
        var shell = ComputerTemplate.shell.makeComputer(name: "Custom Shell Test")
        shell.customImage = true
        shell.networkEnabled = false
        guard await store.create(shell, source: nil), let shellSession = store.selected else {
            throw ComputerError("Custom shell creation failed.")
        }
        await store.start(shellSession)
        guard shellSession.phase == .running, shellSession.terminal != nil, shellSession.desktop == nil else {
            throw ComputerError("An image without a web port did not default to a terminal.")
        }
        await store.stop(shellSession, force: true)
        print("CUSTOM TEST PASSED: image startup command, HTTP web display, recovery terminal, transparent colours, and no-port shell workspace")
        try? FileManager.default.removeItem(at: root)
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
        let testBundle = Bundle.main.bundleIdentifier?.hasSuffix(".tests") == true
        let menuName = testBundle ? "Computer Tests" : "Computer"
        let displayName = testBundle ? "Noodle Computer Tests" : "Noodle Computer"
        guard Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String == menuName,
              Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String == displayName,
              Bundle.main.bundleURL.lastPathComponent == "\(displayName).app" else {
            throw ComputerError("Short menu name must not replace the full application name.")
        }
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              appMenu.items.contains(where: { $0.title == "About Noodle Computer" }) else {
            throw ComputerError("Application menu must retain the full About name.")
        }
        print("APPLICATION NAME TEST PASSED: menu=\(menuName), app=\(displayName), About retains full name")
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
                    throw ComputerError("Toolbar symbol differs from Noodle's native label: \(actual), \(expected)")
                }
            }
        }
        print("TOOLBAR SIZING TEST PASSED: all icons and busy states match Noodle's intrinsic edit-label dimensions")
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
        let session = ComputerSession(ComputerTemplate.desktop.makeComputer())
        // Layout needs a WebKit surface, not a running guest or image download.
        session.desktop = DesktopConnection(url: URL(string: "https://127.0.0.1:1/")!,
                                             certificate: Data(), password: "layout-test")
        let host = NSHostingView(rootView: ComputerDetailView(store: store, session: session))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.titled, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "desktop-layout-test")
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        func webView(in view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.compactMap { webView(in: $0) }.first
        }
        func terminalSurface(in view: NSView) -> ComputerTerminalSurface? {
            if let terminal = view as? ComputerTerminalSurface { return terminal }
            return view.subviews.compactMap { terminalSurface(in: $0) }.first
        }
        let browser = session.browser!
        let shell = ComputerSession(ComputerTemplate.shell.makeComputer())
        var appearance = ComputerAppearance()
        appearance.terminalOpacity = 0.5
        shell.computer.appearance = appearance
        shell.terminal = GuestTerminal()
        for size in [NSSize(width: 900, height: 650), NSSize(width: 700, height: 480)] {
            window.setContentSize(size)
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            guard let web = webView(in: host) else { throw ComputerError("Desktop surface is missing.") }
            let frame = web.convert(web.bounds, to: nil)
            let usable = window.contentLayoutRect
            guard frame.height > 100, abs(usable.maxY - frame.maxY - 4) < 1 else {
                throw ComputerError("Desktop overlaps native toolbar: \(frame), usable \(usable)")
            }
            guard abs(frame.minY - 8) < 1 else {
                throw ComputerError("Display bottom must match the sidebar's 8-point inset: \(frame)")
            }
            guard abs(usable.maxX - frame.maxX - 8) < 1, abs(frame.minX - usable.minX - 12) < 1 else {
                throw ComputerError("Display must keep an 8-point outer margin and 12-point panel gap: \(frame)")
            }
            host.rootView = ComputerDetailView(store: store, session: shell)
            try await Task.sleep(for: .milliseconds(200))
            host.layoutSubtreeIfNeeded()
            guard let surface = terminalSurface(in: host) else { throw ComputerError("Shell surface is missing.") }
            let shellFrame = surface.convert(surface.bounds, to: nil)
            guard surface.layer?.backgroundColor?.alpha == 0.5,
                  surface.terminal.backgroundOpacity == 0,
                  surface.terminal.layer?.backgroundColor?.alpha == 0 else {
                throw ComputerError("Terminal background must be composited exactly once.")
            }
            guard abs(shellFrame.minX - frame.minX) < 1, abs(shellFrame.minY - frame.minY) < 1,
                  abs(shellFrame.width - frame.width) < 1, abs(shellFrame.height - frame.height) < 1,
                  abs(surface.terminal.frame.minX - 12) < 1,
                  abs(surface.terminal.frame.minY - 12) < 1 else {
                throw ComputerError("Shell and WebKit geometry differ: \(shellFrame), \(frame); text \(surface.terminal.frame)")
            }
            // Collapsing changes only the outer left inset, for both surfaces.
            for candidate in [shell, session] {
                host.rootView = ComputerDetailView(store: store, session: candidate, sidebarCollapsed: true)
                try await Task.sleep(for: .milliseconds(200))
                host.layoutSubtreeIfNeeded()
                guard let display: NSView = candidate === shell ? terminalSurface(in: host) : webView(in: host) else {
                    throw ComputerError("Collapsed display is missing.")
                }
                let collapsed = display.convert(display.bounds, to: nil)
                guard abs(collapsed.minX - usable.minX - 8) < 1,
                      abs(usable.maxX - collapsed.maxX - 8) < 1,
                      abs(collapsed.minY - frame.minY) < 1,
                      abs(collapsed.height - frame.height) < 1 else {
                    throw ComputerError("Collapsed sidebar must give both displays matching 8-point side insets: \(collapsed)")
                }
            }
            host.rootView = ComputerDetailView(store: store, session: session)
            try await Task.sleep(for: .milliseconds(200))
            guard webView(in: host) === web, session.browser === browser else {
                throw ComputerError("Switching computers recreated WebKit.")
            }
            host.layoutSubtreeIfNeeded()
            guard abs(web.convert(web.bounds, to: nil).minX - frame.minX) < 1 else {
                throw ComputerError("Expanding the sidebar did not restore the 12-point panel gap.")
            }
        }
        // Verify page state survives detaching and reattaching the display, not just its URL.
        browser.view.loadHTMLString("<html><body>Retained display<script>window.noodleFixtureLoaded = true</script></body></html>", baseURL: browser.connection.url)
        var fixtureLoaded = false
        for _ in 0..<100 {
            if (try? await browser.view.evaluateJavaScript("window.noodleFixtureLoaded === true")) as? Bool == true {
                fixtureLoaded = true; break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard fixtureLoaded else { throw ComputerError("WebKit did not load the retention fixture.") }
        _ = try await browser.view.evaluateJavaScript("window.noodleRetainedState = 'unchanged'")
        host.rootView = ComputerDetailView(store: store, session: shell)
        try await Task.sleep(for: .milliseconds(200))
        host.rootView = ComputerDetailView(store: store, session: session)
        try await Task.sleep(for: .milliseconds(200))
        guard try await browser.view.evaluateJavaScript("window.noodleRetainedState") as? String == "unchanged" else {
            throw ComputerError("Switching computers reloaded the page.")
        }
        print("DISPLAY LAYOUT TEST PASSED: identical Shell/WebKit bounds, 8-point collapsed side/outer/bottom margins, restored 12-point expanded panel gap and terminal inset, retained browser and page state")
    }

    static func checkDesktop() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoodleDesktop-Verification")
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
        guard session.phase == .running, session.desktop != nil else {
            throw ComputerError("Desktop startup failed: \(session.console)")
        }
        await store.execute("for attempt in 1 2 3 4 5 6 7 8 9 10; do if pgrep -x Xvnc && pgrep -x openbox; then exit 0; fi; sleep 1; done; exit 1", in: session)
        let result = session.console
        guard result.contains("[Exit 0]"), session.desktop != nil else {
            await store.stop(session, force: true)
            throw ComputerError("Desktop processes did not start: \(result)")
        }
        let host = NSHostingView(rootView: ComputerDetailView(store: store, session: session))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func webView(in view: NSView) -> WKWebView? {
            if let web = view as? WKWebView { return web }
            return view.subviews.compactMap { webView(in: $0) }.first
        }
        var rendered = false
        var lastState = "No web view"
        for _ in 0..<60 {
            try await Task.sleep(for: .seconds(1))
            if let web = webView(in: host) {
                lastState = (try? await web.evaluateJavaScript("JSON.stringify({classes:document.documentElement.className,canvases:[...document.querySelectorAll('canvas')].map(c=>[c.width,c.height]),text:document.body.innerText.slice(0,500)})")) as? String ?? "Page not ready"
                if (try? await web.evaluateJavaScript("document.documentElement.classList.contains('noVNC_connected') && [...document.querySelectorAll('canvas')].some(c=>c.width>100 && c.height>100)")) as? Bool == true {
                    try await Task.sleep(for: .seconds(3))
                    let snapshot = try await web.takeSnapshot(configuration: nil)
                    if let data = snapshot.tiffRepresentation {
                        try data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("NoodleDesktop-Verification.tiff"))
                    }
                    rendered = true
                    break
                }
            }
        }
        if rendered {
            let originalWebView = webView(in: host)
            // Freeze only this isolated test guest's display server, not its VM.
            session.console = ""
            await store.execute("pkill -STOP -x Xvnc && ps -o stat= -p $(pgrep -x Xvnc) | grep -q T", in: session)
            guard session.console.contains("[Exit 0]") else {
                await store.stop(session, force: true)
                throw ComputerError("Could not pause the test desktop display server.")
            }
            await store.toggleTerminal(session)
            guard session.showingTerminal, let terminal = session.terminal else {
                await store.stop(session, force: true)
                throw ComputerError("Desktop recovery terminal did not open.")
            }
            terminal.io.send(Data("export NOODLE_RECOVERY=alive; printf '\\n__RECOVERY_%s__\\n' READY\r".utf8))
            func terminalScreen() -> String {
                String(decoding: terminal.view.getTerminal().getBufferAsData(), as: UTF8.self)
            }
            for _ in 0..<100 {
                if terminalScreen().contains("__RECOVERY_READY__") { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard terminalScreen().contains("__RECOVERY_READY__") else {
                await store.stop(session, force: true)
                throw ComputerError("Terminal stopped responding while the desktop was paused.")
            }
            await store.toggleTerminal(session)
            guard !session.showingTerminal else { throw ComputerError("Show Desktop did not switch back.") }
            await store.toggleTerminal(session)
            guard session.terminal === terminal else { throw ComputerError("Switching replaced the shell session.") }
            terminal.io.send(Data("printf '\\n__PRESERVED_%s__\\n' \"$NOODLE_RECOVERY\"\r".utf8))
            for _ in 0..<100 {
                if terminalScreen().contains("__PRESERVED_alive__") { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard terminalScreen().contains("__PRESERVED_alive__") else {
                await store.stop(session, force: true)
                throw ComputerError("Switching lost the shell environment.")
            }
            await store.execute("pkill -CONT -x Xvnc", in: session)
            await store.toggleTerminal(session)
            host.layoutSubtreeIfNeeded()
            guard webView(in: host) === originalWebView else {
                await store.stop(session, force: true)
                throw ComputerError("Switching replaced the desktop connection.")
            }
            print("RECOVERY TERMINAL TEST PASSED: shell works with paused desktop; switching preserves its session")
        }
        await store.stop(session, force: true)
        window.close()
        guard rendered else { throw ComputerError("Desktop display did not connect: \(lastState)") }
        print("DESKTOP TEST PASSED: real Launcher desktop, Xvnc/Openbox, authenticated HTTPS, pinned certificate and connected WebKit desktop canvas")
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
        let browser = session.browser
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
                  session.phase == .running, session.browser === browser else {
                throw ComputerError("Terminal recovery failed or replaced the computer/desktop (case \(index)).")
            }
        }
        print("TERMINAL RECONNECTION TEST PASSED: exit, Ctrl-D, killed shell; same terminal, computer and browser")
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
        let packageCheck = networkEnabled ? " && apk add --no-cache jq && jq --version" : ""
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
}
