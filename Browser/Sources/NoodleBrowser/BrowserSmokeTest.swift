import AppKit
import BrowserBridge
import BrowserCore
import WebKit
import SwiftUI

/// Runs only when explicitly requested. Uses UUID-isolated profiles and fake
/// loopback authentication; never reads or operates a user's browser profiles.
@MainActor enum BrowserSmokeTest {
    static func require(_ value: Bool, _ message: String) throws { if !value { throw BrowserError(message) } }
    static func eventually(_ label: String, _ check: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if (try? await check()) == true { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw BrowserError("Timed out: " + label)
    }
    static func runAndExit() async {
        setbuf(stdout, nil)
        do {
            let args = CommandLine.arguments
            func arg(_ name: String) throws -> String {
                guard let i = args.firstIndex(of: name), i+1 < args.count else { throw BrowserError("Missing smoke argument " + name) }
                return args[i+1]
            }
            guard let id = UUID(uuidString: try arg("--smoke-id")), let port = Int(try arg("--smoke-port")), (1...65535).contains(port) else { throw BrowserError("Invalid smoke fixture.") }
            let restore = args.contains("--restore")
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("BrowserSmoke/" + id.uuidString)
            let library = BrowserLibrary(root: root)
            let transfers = root.appendingPathComponent("Transfers")
            try FileManager.default.createDirectory(at: transfers, withIntermediateDirectories: true)
            let runtime = BrowserRuntime(library: library, transferRoot: args.contains("--serve-smoke") ? nil : transfers)
            if args.contains("--serve-smoke") {
                try require(library.profiles.count == 2, "Run the smoke fixture before serving it")
                let socket = try BrowserConnection.socketURL().deletingLastPathComponent().appendingPathComponent("t.sock")
                runtime.startServer(socket: socket)
                try require(runtime.failure == nil, runtime.failure ?? "Server error")
                print("BROWSER_SMOKE_SERVER_READY")
                for _ in 0..<900 { try await Task.sleep(for: .seconds(1)) }
                runtime.shutdown(); exit(0)
            }
            let focus = BrowserFocusProbe()
            defer { focus.stop() }
            let base = "http://127.0.0.1:\(port)"
            if args.contains("--cleanup") {
                for profile in library.profiles { try await runtime.removeBrowser(profile.id) }
                try FileManager.default.removeItem(at: root)
                print("BROWSER_SMOKE_CLEANED"); exit(0)
            }
            if restore {
                try require(library.profiles.count == 2, "Profiles did not persist")
                let profile = library.profiles[0], other = library.profiles[1]
                try require(try library.history(profile.id, query: "history-marker").total == 1, "History did not persist across restart")
                try require(try library.bookmarks(profile.id, query: "Smoke bookmark").total == 1, "Bookmark did not persist across restart")
                try require(try library.bookmarks(other.id).total == 0, "Bookmarks leaked between profiles")
                print("PASS history and bookmark persistence across process restart")
                let tab = try runtime.tab(browserID: profile.id, tabID: profile.tabs[0].id)
                let isolated = try runtime.tab(browserID: other.id, tabID: other.tabs[0].id)
                try await eventually("restored first tab") { try await tab.evaluate("return document.readyState==='complete' && document.querySelector('#login')!==null;") as? Bool == true }
                try await eventually("restored second tab") { try await isolated.evaluate("return document.readyState==='complete' && document.querySelector('#login')!==null;") as? Bool == true }
                try require(try await tab.evaluate("return (await (await fetch('/auth-state')).json()).authenticated && localStorage.getItem('remembered')==='yes';") as? Bool == true, "Signed-in profile lost authentication after restart")
                try require(try await isolated.evaluate("return !(await (await fetch('/auth-state')).json()).authenticated && localStorage.getItem('remembered')===null;") as? Bool == true, "Authentication leaked to second profile")
                try require(try await tab.evaluate("return await new Promise((resolve,reject)=>{const r=indexedDB.open('noodle-fixture',1);r.onerror=()=>reject(r.error);r.onsuccess=()=>{const db=r.result;const q=db.transaction('values').objectStore('values').get('state');q.onsuccess=()=>{db.close();resolve(q.result==='saved')};q.onerror=()=>reject(q.error)}});") as? Bool == true, "IndexedDB did not persist")
                try require(profile.muted && other.muted, "Mute did not persist")
                try require(profile.downloads.contains { $0.state == "complete" && $0.filename == "report.txt" }, "Download record did not persist")
                print("PASS restart: persistent HTTP-only login, localStorage, IndexedDB, isolated profile, tab IDs, downloads and mute")
                runtime.shutdown()

            } else {
                try require(library.profiles.isEmpty, "Use a fresh smoke UUID")
                let profile = try library.create(name: "Smoke authenticated"), other = try library.create(name: "Smoke isolated")
                func open(_ id: UUID) async throws -> BrowserTab {
                    var request = BrowserRequest(.open, browserID: id); request.url = base
                    let response = try await runtime.perform(request)
                    return try runtime.tab(browserID: id, tabID: response.tabID!)
                }
                let tab = try await open(profile.id), isolated = try await open(other.id)
                try await eventually("fixture ready") { try await tab.evaluate("return document.readyState==='complete' && document.querySelector('#login')!==null;") as? Bool == true }
                try await eventually("isolated fixture ready") { try await isolated.evaluate("return document.readyState==='complete' && document.querySelector('#login')!==null;") as? Bool == true }
                let inspect = try await tab.inspect(frame: nil)
                try require(inspect.contains("Noodle Browser verification"), "Inspect missing page content")
                try await eventually("iframe registration") { tab.frames.values.contains { !$0.isMainFrame } }
                let frame = tab.frames.first { !$0.value.isMainFrame }!.key
                try require(try await tab.evaluate("return document.querySelector('#frame-text').textContent;", frame: frame) as? String == "Frame control works", "Frame evaluation failed")
                var fill = BrowserRequest(.fill, browserID: profile.id, tabID: tab.id); fill.target = "#username"; fill.text = "fixture user"
                _ = try await runtime.perform(fill)
                try await tab.click(target: "#sign-in", x: nil, y: nil, frame: nil)
                try await eventually("native click sign-in") { try await tab.evaluate("return document.body.dataset.signedIn==='yes';") as? Bool == true }
                try require(try await tab.evaluate("return (await (await fetch('/auth-state')).json()).authenticated;") as? Bool == true, "Server did not observe login")
                try require(try await isolated.evaluate("return !(await (await fetch('/auth-state')).json()).authenticated;") as? Bool == true, "Profile cookie isolation failed")
                _ = try await tab.evaluate("return await new Promise((resolve,reject)=>{const r=indexedDB.open('noodle-fixture',1);r.onupgradeneeded=()=>r.result.createObjectStore('values');r.onerror=()=>reject(r.error);r.onsuccess=()=>{const db=r.result,tx=db.transaction('values','readwrite');tx.objectStore('values').put('saved','state');tx.oncomplete=()=>{db.close();resolve(true)};tx.onerror=()=>reject(tx.error)}});")
                print("PASS DOM inspection, iframe, fill, native click, authenticated request, profile isolation, IndexedDB write")
                try await verifyWebMCP(runtime, browserID: profile.id, otherID: other.id, base: base)
                if args.contains("--webmcp-demos") { try await verifyPublicWebMCPDemos(runtime, browserID: profile.id) }
                if args.contains("--webmcp-only") {
                    runtime.shutdown()
                    print("BROWSER_WEBMCP_OK"); fflush(stdout); exit(0)
                }
                fill.target = "#key"; fill.text = "keys"; _ = try await runtime.perform(fill)
                try tab.press("Enter")
                try await eventually("native key") { try await tab.evaluate("return document.querySelector('#key').dataset.key==='Enter';") as? Bool == true }
                for i in 1...2 {
                    let transferID = UUID(), payload = Data("upload-\(i)-contents".utf8)
                    let staging = try BrowserTransferFiles.staging(root: transfers, id: transferID, create: true)
                    try payload.write(to: staging)
                    var upload = BrowserRequest(.upload, browserID: profile.id, tabID: tab.id)
                    upload.target = "#file"; upload.transferID = transferID; upload.filename = "upload\(i).txt"
                    let response = try await runtime.perform(upload)
                    try require(response.byteCount == Int64(payload.count), "Upload byte count mismatch")
                    try await eventually("uploaded file available") { try await tab.evaluate("return document.querySelector('#file').files.length===1;") as? Bool == true }
                    try require(try await tab.evaluate("return await document.querySelector('#file').files[0].text();") as? String == String(decoding: payload, as: UTF8.self), "WebKit could not read staged upload bytes")
                }
                print("PASS native key, two programmatic uploads without file dialogs")
                _ = try await tab.evaluate("window.addEventListener('error',e=>window.lastError=e.message);document.querySelector('#blob').addEventListener('click',()=>window.blobClicked=true); return true;")
                try await tab.click(target: "#blob", x: nil, y: nil, frame: nil)
                try await eventually("blob click delivered") { try await tab.evaluate("return window.blobClicked===true;") as? Bool == true }
                print("PASS download button received native click", try await tab.evaluate("return window.lastError || 'no error';") ?? "unknown")
                try await eventually("blob download") { try library.profile(profile.id).downloads.contains { $0.state == "complete" } }
                let download = try library.profile(profile.id).downloads.first { $0.state == "complete" }!
                var get = BrowserRequest(.download, browserID: profile.id); get.fileID = download.id; get.transferID = UUID()
                let target = try BrowserTransferFiles.staging(root: transfers, id: get.transferID!, create: true)
                _ = try await runtime.perform(get)
                try require(try String(contentsOf: target, encoding: .utf8) == "noodle-download-contents", "Download bytes changed")
                let capture = try await tab.snapshot()
                let image = NSBitmapImageRep(data: capture)!
                var colours = Set<String>()
                for x in stride(from: 0, to: image.pixelsWide, by: 20) {
                    for y in stride(from: 0, to: image.pixelsHigh, by: 20) { colours.insert(image.colorAt(x:x,y:y)!.description) }
                }
                try require(colours.count > 8, "Screenshot is blank")
                let captureURL = root.appendingPathComponent("screenshot.png"); try capture.write(to: captureURL)
                print("PASS blob download and byte-exact retrieval, nonblank hidden screenshot: \(captureURL.path)")
                try await tab.click(target: "#popup", x: nil, y: nil, frame: nil)
                try await eventually("popup") { try library.profile(profile.id).tabs.count == 2 }
                let popupInfo = try library.profile(profile.id).tabs.last!
                let popup = try runtime.tab(browserID: profile.id, tabID: popupInfo.id)
                try await eventually("popup ready") { try await popup.evaluate("return location.pathname==='/popup';") as? Bool == true }
                try require(try await popup.evaluate("return !!window.opener && (await (await fetch('/auth-state')).json()).authenticated;") as? Bool == true, "Popup lost opener or profile")
                try runtime.closeTab(browserID: profile.id, tabID: popup.id)
                try await tab.click(target: "#confirm", x: nil, y: nil, frame: nil)
                try await eventually("dialog") { tab.dialog != nil }
                var dialog = BrowserRequest(.dialog, browserID: profile.id, tabID: tab.id); dialog.accept = true
                _ = try await runtime.perform(dialog)
                try await eventually("dialog reply") { try await tab.evaluate("return window.dialogResult===true;") as? Bool == true }
                try runtime.setPaused(true, browserID: profile.id)
                do { _ = try await runtime.perform(fill); throw BrowserError("Paused control accepted fill") }
                catch let error as BrowserError { try require(error.message.contains("paused"), "Unexpected pause error") }
                try runtime.setPaused(false, browserID: profile.id)
                try focus.verify()
                _ = try await tab.evaluate("window.fixtureAudio=new Audio('/silent.wav');fixtureAudio.loop=true;fixtureAudio.preload='auto';const b=document.createElement('button');b.id='media-test';b.textContent='Play silent fixture';b.onclick=()=>fixtureAudio.play().then(()=>window.fixturePlayed=true).catch(e=>window.fixtureMediaError=e.name);document.body.append(b);return true;")
                try await eventually("silent audio loaded") { try await tab.evaluate("return fixtureAudio.readyState>=2;") as? Bool == true }
                try await tab.click(target: "#media-test", x: nil, y: nil, frame: nil)
                try await Task.sleep(for: .milliseconds(300))
                let mediaState = await tab.web.requestMediaPlaybackState()
                let mediaDetails = try await tab.evaluate("return {paused:fixtureAudio.paused,ready:fixtureAudio.readyState,played:!!window.fixturePlayed,error:window.fixtureMediaError||null};")
                print("MEDIA", mediaState.rawValue, mediaDetails ?? "unknown")
                try require(mediaState != .playing, "Muted browser played media")
                try require(try await tab.evaluate("return fixtureAudio.paused;") as? Bool == true, "Muted media advanced")
                print("PASS popup opener/authentication, dialogs, pause, media silence, no browser activation")
                try require(try library.history(profile.id).total > 0, "Navigation did not record history")
                try require(try library.history(profile.id, query: "/frame").total == 0, "Subframe entered browsing history")
                _ = try await tab.evaluate("history.pushState({},'', '/history-marker');document.title='History marker';return true;")
                try await eventually("same-document history") { try library.history(profile.id, query: "history-marker").entries.first?.title == "History marker" }
                _ = try await tab.evaluate("document.title='Updated history marker';return true;")
                try await eventually("history title update") { try library.history(profile.id, query: "history-marker").entries.first?.title == "Updated history marker" }
                try require(try library.history(profile.id, query: "history-marker").total == 1, "Title observation duplicated history")
                var bookmark = BrowserRequest(.bookmarkAdd, browserID: profile.id)
                bookmark.url = base + "/"; bookmark.title = "Smoke bookmark"
                _ = try await runtime.perform(bookmark)
                _ = try await tab.evaluate("history.replaceState({},'', '/');return true;")
                try await eventually("restore fixture URL") { tab.info.url == base + "/" }
                print("PASS recorded navigation, same-document history, title updates, frame exclusion and bookmark creation")
                let presentation = try await runtime.perform(.init(.present, browserID: profile.id, tabID: tab.id))
                guard let reference = presentation.reference, let image = reference.previewImage else { throw BrowserError("Missing page reference preview") }
                try require(NSImage(data: image) != nil, "Invalid reference snapshot")
                let referenceFile = root.appendingPathComponent("Page." + BrowserBuildIdentity.current.fileExtension)
                try JSONEncoder().encode(reference).write(to: referenceFile)
                let saved = try BrowserReference.read(referenceFile)
                try require(try runtime.openReference(saved) == tab.id, "Reference duplicated an existing tab")
                var closed = saved; closed.tabID = UUID()
                let restoredID = try runtime.openReference(closed)
                try require(restoredID != tab.id, "Closed reference did not create a new tab")
                let restoredTab = try runtime.tab(browserID: profile.id, tabID: restoredID)
                try await eventually("reference preserves authentication") {
                    try await restoredTab.evaluate("return (await (await fetch('/auth-state')).json()).authenticated;") as? Bool == true
                }
                try runtime.closeTab(browserID: profile.id, tabID: restoredID)
                var missing = saved; missing.browser.id = UUID()
                var rejected = false
                do { _ = try runtime.openReference(missing) } catch { rejected = true }
                try require(rejected && library.profiles.count == 2, "Reference recreated a deleted browser")
                print("PASS preview reference, exact-tab reuse, closed-tab restoration, signed-in profile and missing-browser rejection")
                for kind in [BrowserRecordsKind.history, .bookmarks] {
                    let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 476, height: 496), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                    panel.isReleasedWhenClosed = false
                    let view = NSHostingView(rootView: BrowserRecordsView(kind: kind, browserID: profile.id, library: library, currentURL: base, currentTitle: "Fixture", open: { _, _ in }))
                    panel.contentView = view; view.frame = panel.contentLayoutRect; view.layoutSubtreeIfNeeded()
                    try await Task.sleep(for: .milliseconds(300))
                    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: root.appendingPathComponent(kind.rawValue.lowercased() + ".png")) }
                    }
                    panel.contentView = nil; panel.close()
                }
                let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 700), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                let browserPresentation = BrowserPresentation(library: library, runtime: runtime, defaults: nil)
                browserPresentation.selection = profile.id; browserPresentation.selectTab(tab.id)
                let host = NSHostingView(rootView: BrowserLibraryView(presentation: browserPresentation).preferredColorScheme(.dark))
                window.contentView = host; host.frame = window.contentLayoutRect; host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(300))
                try await verifyTabSwitching(browserPresentation, tab: tab, window: window, url: URL(string: base)!)
                // WebKit commits its resized rendering surface asynchronously.
                try await Task.sleep(for: .milliseconds(300))
                if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: root.appendingPathComponent("library.png")) }
                }
                window.contentView = nil; window.close()
                // Allow WebKit's asynchronous website storage writes to settle before
                // a second process independently checks persisted authentication.
                _ = await tab.web.configuration.websiteDataStore.httpCookieStore.allCookies()
                try await Task.sleep(for: .seconds(2))
                runtime.shutdown()
            }
            print("BROWSER_SMOKE_OK"); fflush(stdout); exit(0)
        } catch {
            fputs("BROWSER_SMOKE_FAILED: \(error.localizedDescription)\n", stderr); fflush(stderr); exit(1)
        }
    }

    private static func verifyTabSwitching(_ presentation: BrowserPresentation, tab: BrowserTab, window: NSWindow, url: URL) async throws {
        let runtime = presentation.runtime
        let other = try runtime.makeTab(browserID: tab.browserID)
        defer { try? runtime.closeTab(browserID: tab.browserID, tabID: other.id) }
        other.navigate(url)
        try await eventually("second switching tab") { try await other.evaluate("return document.readyState==='complete' && !!document.querySelector('#username');") as? Bool == true }
        presentation.selectTab(tab.id)
        try await eventually("mounted switching tab") { tab.web.window === window }
        try await Task.sleep(for: .milliseconds(300))
        let token = UUID().uuidString
        _ = try await tab.evaluate("""
            window.tabSwitchProbe={token,origin:performance.timeOrigin,resizes:[]};
            window.addEventListener('resize',()=>tabSwitchProbe.resizes.push([innerWidth,innerHeight]));
            document.querySelector('#username').value=token;
            document.documentElement.style.minHeight='3000px';
            scrollTo(0,500);
            return true;
            """, arguments: ["token": token])
        try await eventually("switching scroll position") { try await tab.evaluate("return scrollY===500;") as? Bool == true }
        let size = tab.web.frame.size
        var resizedWhileHidden = false
        for _ in 0..<3 {
            presentation.selectTab(other.id)
            try await eventually("switch away") { tab.web.window === tab.surface && other.web.window === window }
            resizedWhileHidden = resizedWhileHidden || tab.web.frame.size != size
            try await Task.sleep(for: .milliseconds(100))
            presentation.selectTab(tab.id)
            try await eventually("switch back") { tab.web.window === window }
            try await Task.sleep(for: .milliseconds(100))
        }
        let state = try await tab.evaluate("""
            return {sameDocument:window.tabSwitchProbe?.token===token && tabSwitchProbe.origin===performance.timeOrigin,
                form:document.querySelector('#username').value===token,scroll:scrollY, resizes:window.tabSwitchProbe?.resizes};
            """, arguments: ["token": token]) as? [String: Any] ?? [:]
        print("TAB_SWITCH_STATE", state, "resizedWhileHidden:", resizedWhileHidden)
        try require(state["sameDocument"] as? Bool == true, "Switching tabs reloaded the document")
        try require(state["form"] as? Bool == true, "Switching tabs lost unsaved form input")
        try require(!resizedWhileHidden && tab.web.frame.size == size, "Switching tabs changed the page viewport")
        try require(state["scroll"] as? Int == 500, "Switching tabs lost the scroll position")
        try require((state["resizes"] as? [[Int]])?.isEmpty == true, "Switching tabs dispatched page resize events")
        presentation.mode = .history
        try await eventually("hidden page capture") { tab.web.window === tab.surface }
        try require(NSImage(data: try await tab.snapshot()) != nil, "Hidden page screenshot failed after switching tabs")
        presentation.mode = .browser
        try await eventually("return to page") { tab.web.window === window }
        window.setContentSize(NSSize(width: 1140, height: 760))
        try await eventually("actual window resize") {
            guard tab.web.frame.width > size.width else { return false }
            return try await tab.evaluate("return innerWidth===width;", arguments: ["width": tab.web.frame.width]) as? Bool == true
        }
        try require(!window.isVisible && runtime.tabs.values.allSatisfy { !$0.surface.isVisible }
            && !NSApp.windows.contains { $0.isVisible && $0.identifier?.rawValue == "library" },
            "Hidden tab-switch fixture opened a browser window")
        print("PASS repeated tab switching: same document, unsaved input, scroll position and viewport; no switch resize events; hidden screenshots and actual window resizing work; no visible browser windows")
    }
}
