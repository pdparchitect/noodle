import BrowserBridge
import BrowserCore
@testable import NoodleBrowser
import XCTest

/// Someone watching a browser live sees its tab strip above the page, drawn where nobody clicks
/// it directly; their clicks on it select, close and open tabs.
@MainActor final class BrowserLiveViewTests: XCTestCase {
    func testTheTabStripDrawsOffscreenAndKnowsWhatWasClicked() async throws {
        let first = BrowserTabInfo(title: "DAWO.community"), second = BrowserTabInfo(title: "Service Bus")
        let strip = BrowserTabStripPicture()
        var picture: CGImage?
        for _ in 0..<50 {
            picture = strip.render(tabs: [first, second], selected: second.id, address: "https://example.com", editing: false,
                                   width: 800, scale: 2)
            if strip.target(at: CGPoint(x: 790, y: BrowserTabStrip.height / 2)) != nil,
               strip.target(at: CGPoint(x: 400, y: BrowserTabStrip.height + 12)) != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        let image = try XCTUnwrap(picture)
        XCTAssertEqual(image.width, 1600)
        XCTAssertEqual(image.height, Int(BrowserLiveChrome.height * 2))
        XCTAssertGreaterThan(Set(samples(image)).count, 1, "the strip drew nothing")

        let middle = BrowserTabStrip.height / 2
        XCTAssertEqual(strip.target(at: CGPoint(x: 790, y: middle)), .newTab)
        let tabs = (0..<700).compactMap { strip.target(at: CGPoint(x: Double($0), y: middle)) }
        XCTAssertTrue(tabs.contains(.tab(first.id)))
        XCTAssertTrue(tabs.contains(.tab(second.id)))
        XCTAssertTrue(tabs.contains(.close(second.id)))
        // The close button sits over the end of its tab and wins there.
        let closing = try XCTUnwrap((0..<700).first { strip.target(at: CGPoint(x: Double($0), y: middle)) == .close(first.id) })
        XCTAssertEqual(strip.target(at: CGPoint(x: Double(closing) + 2, y: middle)), .close(first.id))
        // Below the tabs, only a live view has a way to go back, forward, reload and go somewhere.
        let row = BrowserTabStrip.height + (BrowserLiveChrome.height - BrowserTabStrip.height) / 2
        let nav = (0..<800).compactMap { strip.target(at: CGPoint(x: Double($0), y: row)) }
        for target in [BrowserTabStripTarget.back, .forward, .reload, .address] { XCTAssertTrue(nav.contains(target), "no \(target)") }
        XCTAssertNil(strip.target(at: CGPoint(x: 10, y: BrowserLiveChrome.height + 5)), "a point on the page hit the chrome")
    }

    /// A tab is as wide whatever its title, so a page naming itself never moves the tabs around it.
    func testATabIsAsWideWhateverItsTitle() async throws {
        let first = BrowserTabInfo(title: "A"), second = BrowserTabInfo(title: "B")
        var named = second; named.title = "A much longer title that the page only sets once it has loaded"
        let short = try await extent(of: second.id, in: [first, second])
        let long = try await extent(of: second.id, in: [first, named])
        XCTAssertEqual(short, long, "the tab changed size with its title")
        let other = try await extent(of: first.id, in: [first, second])
        XCTAssertEqual(other.count, short.count, "tabs differ in width")
    }

    /// A tab that opens, even one a bot opens behind the selected tab, is scrolled into sight;
    /// closing or reordering tabs leaves the strip where it is.
    func testTheStripRevealsATabThatOpens() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        XCTAssertEqual(BrowserTabStrip.opened(from: [a, b], to: [a, b, c]), c)
        XCTAssertEqual(BrowserTabStrip.opened(from: [a, b], to: [a, c, b]), c)
        XCTAssertEqual(BrowserTabStrip.opened(from: [a], to: [a, c, d]), d)
        XCTAssertNil(BrowserTabStrip.opened(from: [a, b, c], to: [a, c]))
        XCTAssertNil(BrowserTabStrip.opened(from: [a, b], to: [b, a]))
    }

    /// The points across the middle of the strip that land on a tab or its close button.
    private func extent(of id: UUID, in tabs: [BrowserTabInfo]) async throws -> ClosedRange<Int> {
        let strip = BrowserTabStripPicture(), middle = BrowserTabStrip.height / 2
        for _ in 0..<50 {
            _ = strip.render(tabs: tabs, selected: tabs.last?.id, address: "", editing: false, width: 800, scale: 1)
            let hits = (0..<800).filter { [.tab(id), .close(id)].contains(strip.target(at: CGPoint(x: Double($0), y: middle))) }
            if let low = hits.first, let high = hits.last, strip.target(at: CGPoint(x: 790, y: middle)) != nil { return low...high }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw XCTSkip("the strip never laid out")
    }

    /// Typing in a live view's address bar replaces the address, as selecting it first would;
    /// Return goes there and Escape leaves it as it was.
    func testTheAddressBarTakesTypingAndGoesOnReturn() {
        var draft = BrowserAddressDraft(address: "https://example.com")
        XCTAssertNil(draft.take(.text("news")))
        XCTAssertNil(draft.take(.text(".ycombinator.com")))
        XCTAssertEqual(draft.text, "news.ycombinator.com")
        XCTAssertNil(draft.take(.key(.backspace)))
        XCTAssertEqual(draft.text, "news.ycombinator.co")
        XCTAssertEqual(draft.take(.key(.enter)), .go("news.ycombinator.co"))

        var cleared = BrowserAddressDraft(address: "https://example.com")
        XCTAssertNil(cleared.take(.key(.backspace)))
        XCTAssertEqual(cleared.text, "", "the first backspace kept the old address")
        XCTAssertEqual(BrowserAddressDraft(address: "about:blank").text, "", "a new tab showed about:blank to type over")
        var left = BrowserAddressDraft(address: "https://example.com")
        XCTAssertEqual(left.take(.key(.escape)), .cancel)
        XCTAssertEqual(left.take(.key(.enter)), .go("https://example.com"), "Return on an untouched address stayed put")
    }

    /// Someone watching from another device who clicks a page's upload button gets no file picker
    /// on this Mac, where nobody may be to close it, and the live view says why.
    func testAnUploadClickedInALiveViewOpensNoPickerOnThisMac() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        let browser = try library.create(name: "Work").id
        let tab = try runtime.makeTab(browserID: browser)
        defer { if let sheet = tab.surface.attachedSheet { tab.surface.endSheet(sheet) } }
        tab.web.loadHTMLString("<input type=file style='position:fixed;inset:0;width:100%;height:100%'>", baseURL: nil)
        for _ in 0..<250 where try await tab.evaluate("return document.readyState") as? String != "complete" {
            try await Task.sleep(for: .milliseconds(20))
        }
        tab.watched = true
        let view = BrowserLiveView(browserID: browser, runtime: runtime)
        let point = (x: 200.0, y: BrowserLiveChrome.height + 200)
        try view.apply(.pointer(.down, x: point.x, y: point.y, clickCount: 1))
        try view.apply(.pointer(.up, x: point.x, y: point.y, clickCount: 1))
        for _ in 0..<250 where tab.info.error == nil && tab.surface.attachedSheet == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(tab.surface.attachedSheet, "a file picker opened on this Mac")
        XCTAssertEqual(tab.info.error, BrowserTab.liveViewUploadNote)
        XCTAssertTrue(tab.web is BrowserPageWebView)
        let picture = try await view.picture()
        XCTAssertGreaterThan(picture.size.height, tab.web.bounds.height + BrowserLiveChrome.height, "the live view did not show the note")
    }


    /// A person watching from another device chooses a file there, and that file is what the page gets.
    func testFilesChosenByTheViewerReachThePageAndTheForm() async throws {
        let tab = try await fileTab("<form id=form><input id=f type=file name=photo style='position:fixed;inset:0;width:100%;height:100%'></form>")
        tab.runtime?.supplyViewerFiles = { multiple, directories in
            XCTAssertFalse(multiple)
            XCTAssertFalse(directories)
            return .chosen([("id.png", Data("photo".utf8))])
        }
        try await clickPage(tab)
        let sent = try await waitString(tab, """
            const file = document.querySelector('#f').files[0]
            const data = new FormData(document.querySelector('#form'))
            const part = data.get('photo')
            return file && part instanceof File && file.name === 'id.png' && part.name === 'id.png' && part.size === 5 ? 'yes' : 'no'
            """)
        XCTAssertEqual(sent, "yes")
        XCTAssertNil(tab.surface.attachedSheet, "a file picker opened on this Mac")
    }

    /// Several files when the input allows them, and only one when it does not.
    func testSeveralFilesOnlyWhenTheInputAllowsThem() async throws {
        let several = try await fileTab("<input id=f type=file multiple style='position:fixed;inset:0;width:100%;height:100%'>")
        several.runtime?.supplyViewerFiles = { multiple, _ in
            XCTAssertTrue(multiple)
            return .chosen([("a.txt", Data("a".utf8)), ("b.txt", Data("b".utf8))])
        }
        try await clickPage(several)
        let severalCount = try await waitString(several, "return String(document.querySelector('#f').files.length)")
        XCTAssertEqual(severalCount, "2")

        let one = try await fileTab("<input id=f type=file style='position:fixed;inset:0;width:100%;height:100%'>")
        one.runtime?.supplyViewerFiles = { multiple, _ in
            XCTAssertFalse(multiple)
            return .chosen([("a.txt", Data("a".utf8)), ("b.txt", Data("b".utf8))])
        }
        try await clickPage(one)
        let name = try await waitString(one, "return document.querySelector('#f').files[0] ? document.querySelector('#f').files[0].name : ''")
        let oneCount = try await waitString(one, "return String(document.querySelector('#f').files.length)")
        XCTAssertEqual(name, "a.txt")
        XCTAssertEqual(oneCount, "1")
    }

    /// A custom button that activates the input after a short wait still asks the person watching.
    func testACustomButtonAsksTheViewer() async throws {
        let html = """
        <button id=b style='position:fixed;left:0;top:0;width:160px;height:48px'>Choose</button>
        <input id=f type=file style='display:none'>
        <script>document.getElementById('b').onclick=()=>setTimeout(()=>document.getElementById('f').click(),40)</script>
        """
        let tab = try await fileTab(html)
        tab.runtime?.supplyViewerFiles = { _, _ in .chosen([("card.png", Data("x".utf8))]) }
        try await clickPage(tab, x: 20, y: BrowserLiveChrome.height + 16)
        let name = try await waitString(tab, "return document.querySelector('#f').files[0] ? document.querySelector('#f').files[0].name : ''")
        XCTAssertEqual(name, "card.png")
        XCTAssertNil(tab.surface.attachedSheet)
    }

    /// The bot's upload command still attaches a workspace file without a dialog.
    func testTheBotUploadCommandOpensNoPicker() async throws {
        let tab = try await fileTab("<input id=f type=file style='position:fixed;inset:0;width:100%;height:100%'>")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("note.txt")
        try Data("hello".utf8).write(to: file)
        try await tab.attach([file], target: "#f", frame: nil)
        XCTAssertNil(tab.surface.attachedSheet)
        let name = try await tab.evaluate("return document.querySelector('#f').files[0].name") as? String
        XCTAssertEqual(name, "note.txt")
    }

    private func fileTab(_ html: String) async throws -> BrowserTab {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let library = BrowserLibrary(root: root), runtime = BrowserRuntime(library: library)
        addTeardownBlock { runtime.shutdown(); try? FileManager.default.removeItem(at: root) }
        let browser = try library.create(name: "Work").id
        let tab = try runtime.makeTab(browserID: browser)
        tab.web.loadHTMLString(html, baseURL: nil)
        for _ in 0..<250 where try await tab.evaluate("return document.readyState") as? String != "complete" {
            try await Task.sleep(for: .milliseconds(20))
        }
        tab.watched = true
        return tab
    }

    private func clickPage(_ tab: BrowserTab, x: Double = 200, y: Double? = nil) async throws {
        let view = BrowserLiveView(browserID: tab.browserID, runtime: tab.runtime!)
        let point = (x: x, y: y ?? BrowserLiveChrome.height + 200)
        try view.apply(.pointer(.down, x: point.x, y: point.y, clickCount: 1))
        try view.apply(.pointer(.up, x: point.x, y: point.y, clickCount: 1))
    }

    private func waitString(_ tab: BrowserTab, _ script: String) async throws -> String {
        for _ in 0..<250 {
            if let value = try await tab.evaluate(script) as? String, !value.isEmpty, value != "0", value != "no" { return value }
            try await Task.sleep(for: .milliseconds(20))
        }
        return (try await tab.evaluate(script) as? String) ?? ""
    }

    private func samples(_ image: CGImage) -> [UInt32] {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = context.data!.bindMemory(to: UInt32.self, capacity: image.width * image.height)
        return stride(from: 0, to: image.width * image.height, by: 97).map { pixels[$0] }
    }
}

/// A request from a newer app says which app to update, not that data could not be read.
final class BrowserRequestReadingTests: XCTestCase {
    func testARequestFromANewerAppNamesTheAppToUpdate() {
        let newer = #"{"version":1,"id":"00000000-0000-0000-0000-00000000000A","operation":"surface-teleport"}"#
        XCTAssertThrowsError(try BrowserRequest.read(Data(newer.utf8))) { error in
            XCTAssertEqual(error.localizedDescription, "This needs a newer \(BrowserBuildIdentity.current.appName). Update it.")
        }
    }
}
