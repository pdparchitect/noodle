import AppKit
import BrowserBridge

@MainActor enum BrowserPointerSmokeTest {
    static func run(runtime: BrowserRuntime, browserID: UUID, base: String, root: URL) async throws {
        let tab = try runtime.makeTab(browserID: browserID)
        defer { try? runtime.closeTab(browserID: browserID, tabID: tab.id) }
        tab.navigate(URL(string: base + "/pointer")!)
        try await BrowserSmokeTest.eventually("pointer fixture") {
            try await tab.evaluate("return document.readyState==='complete' && !!document.querySelector('#menu');") as? Bool == true
        }
        @discardableResult func command(_ operation: BrowserOperation, target: String? = nil, x: Double? = nil, y: Double? = nil, frame: String? = nil, count: Int? = nil) async throws -> BrowserResponse {
            var request = BrowserRequest(operation, browserID: browserID, tabID: tab.id)
            request.target = target; request.x = x; request.y = y; request.frame = frame; request.clickCount = count
            return try await runtime.perform(request)
        }
        func check(_ label: String, _ source: String) async throws {
            try await BrowserSmokeTest.eventually(label) { try await tab.evaluate(source) as? Bool == true }
        }
        let focus = BrowserFocusProbe()
        defer { focus.stop() }
        let desktopPointer = NSEvent.mouseLocation
        let moved = try await command(.move, target: "#menu")
        try BrowserSmokeTest.require(moved.pointer?.visible == true && moved.pointer?.pressed == false, "Pointer state missing")
        try await check("native CSS hover", "return document.querySelector('#menu').matches(':hover') && getComputedStyle(document.querySelector('#menu-button')).display==='block';")
        try await check("native trusted pointer events", "return events.some(e=>e.type==='pointermove' && e.trusted) && events.some(e=>e.type==='pointerover' && e.target==='menu');")
        try await command(.click, target: "#menu-button")
        try await check("revealed menu click", "return menuClicks===1;")
        try await command(.move, target: "#away")
        try await check("hover leave", "return !document.querySelector('#menu').matches(':hover') && events.some(e=>e.type==='pointerleave' && e.target==='menu');")
        try await command(.click, target: "#click")
        try await command(.click, target: "#click", count: 2)
        try await check("single and double clicks", "return clicks===3 && doubles===1;")
        try await command(.move, target: "#menu")
        let status = try await command(.status)
        try BrowserSmokeTest.require(status.pointer?.visible == true && status.pointer?.pressed == false, "Pointer status missing")
        let capture = try await tab.snapshot()
        try capture.write(to: root.appendingPathComponent("pointer.png"))
        let bitmap = NSBitmapImageRep(data: capture)!
        let p = tab.pointer.state
        let colour = bitmap.colorAt(x: Int(p.x * Double(bitmap.pixelsWide) / tab.web.bounds.width), y: Int(p.y * Double(bitmap.pixelsHigh) / tab.web.bounds.height))!.usingColorSpace(.deviceRGB)!
        try BrowserSmokeTest.require(colour.greenComponent > 0.6 && colour.blueComponent > 0.7 && colour.redComponent < 0.2, "Screenshot did not include cyan pointer")
        try BrowserSmokeTest.require(tab.pointer.overlay.superview === tab.web && tab.pointer.overlay.hitTest(.zero) == nil, "Pointer overlay intercepted the page")
        try BrowserSmokeTest.require(tab.web.subviews.last === tab.pointer.overlay, "Pointer overlay is behind WebKit content")
        let overlay = tab.pointer.overlay
        if let pixels = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds) {
            overlay.cacheDisplay(in: overlay.bounds, to: pixels)
            let centre = pixels.colorAt(x: Int(p.x * Double(pixels.pixelsWide) / overlay.bounds.width),
                y: Int(p.y * Double(pixels.pixelsHigh) / overlay.bounds.height))!.usingColorSpace(.deviceRGB)!
            try BrowserSmokeTest.require(centre.alphaComponent > 0.9 && centre.blueComponent > 0.7, "Native cursor overlay did not draw")
        } else { throw BrowserError("Native cursor overlay cannot render") }
        var rejected = false
        do { try await command(.move, target: "#covered") } catch { rejected = true }
        try BrowserSmokeTest.require(rejected, "Covered element accepted")
        do { try await command(.move, x: -1, y: 5); throw BrowserError("Outside coordinate accepted") }
        catch let error as BrowserError { try BrowserSmokeTest.require(!error.message.contains("accepted"), error.message) }
        try await BrowserSmokeTest.eventually("pointer frame registrations") { tab.frames.values.filter { !$0.isMainFrame }.count == 2 }
        let same = tab.frames.first { !$0.value.isMainFrame && $0.value.request.url?.host == "127.0.0.1" }!.key
        try await command(.move, target: "#frame-button", frame: same)
        try await BrowserSmokeTest.eventually("same-origin frame hover") {
            try await tab.evaluate("return document.querySelector('button').matches(':hover');", frame: same) as? Bool == true
        }
        try await command(.click, target: "#frame-button", frame: same)
        try await BrowserSmokeTest.eventually("same-origin frame native click") { try await tab.evaluate("return clicks===1;", frame: same) as? Bool == true }
        let cross = tab.frames.first { $0.value.request.url?.host == "localhost" }!.key
        rejected = false
        do { try await command(.move, target: "#frame-button", frame: cross) } catch { rejected = true }
        try BrowserSmokeTest.require(rejected, "Cross-origin selector accepted")
        let framePoint = try await tab.evaluate("const f=document.querySelector('#cross');f.scrollIntoView({block:'center',behavior:'instant'});const r=f.getBoundingClientRect();return {x:r.x+50,y:r.y+35};") as! [String: Double]
        try await command(.click, x: framePoint["x"], y: framePoint["y"])
        try await BrowserSmokeTest.eventually("cross-origin coordinate click") { try await tab.evaluate("return clicks===1;", frame: cross) as? Bool == true }
        try await command(.move, target: "#click")
        try runtime.setPaused(true, browserID: browserID)
        try BrowserSmokeTest.require(!tab.pointer.state.visible && !tab.pointer.pressed, "Pause left a virtual press active")
        do { try await command(.move, target: "#menu"); throw BrowserError("Paused pointer accepted") }
        catch let error as BrowserError { try BrowserSmokeTest.require(error.message.contains("paused"), error.message) }
        try runtime.setPaused(false, browserID: browserID)
        try await command(.move, target: "#menu")
        try await command(.mouseReset)
        try await check("reset clears CSS hover", "return !document.querySelector('#menu').matches(':hover');")
        try BrowserSmokeTest.require(!tab.pointer.state.visible, "Reset left pointer visible")
        try await command(.move, target: "#away")
        tab.navigate(URL(string: base + "/pointer")!)
        try await BrowserSmokeTest.eventually("navigation resets pointer") { !tab.pointer.state.visible }
        try focus.verify()
        try BrowserSmokeTest.require(!tab.surface.isVisible, "Pointer opened a window")
        // Observational only: a human can independently move their own mouse while the fixture runs.
        print("POINTER_DESKTOP_POSITION", desktopPointer, NSEvent.mouseLocation)
        print("PASS virtual pointer: native CSS hover/leave, trusted events, revealed menu, single/double clicks, same-origin frame targeting, cross-origin coordinates, screenshot marker, pause/reset/navigation and background focus")
    }
}
