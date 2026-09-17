import BrowserBridge
import BrowserCore
@testable import NoodleBrowser
import XCTest

final class BrowserRuntimeTests: XCTestCase {
    @MainActor func testRecordCommandsRespectPauseAndProfileOwnership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), a = try library.create(name: "A"), b = try library.create(name: "B")
        let runtime = BrowserRuntime(library: library)
        var add = BrowserRequest(.bookmarkAdd, browserID: a.id); add.url = "https://example.com"; add.title = "Example"
        let response = try await runtime.perform(add)
        let bookmark = try XCTUnwrap(response.bookmark)
        var update = BrowserRequest(.bookmarkUpdate, browserID: b.id); update.bookmarkID = bookmark.id; update.title = "Wrong profile"
        do { _ = try await runtime.perform(update); XCTFail("Cross-profile bookmark changed") } catch {}
        update.browserID = a.id; update.title = "Saved"
        let edited = try await runtime.perform(update); XCTAssertEqual(edited.bookmark?.title, "Saved")
        _ = try library.recordVisit(a.id, url: "https://example.com", title: "Visited")
        try runtime.setPaused(true, browserID: a.id)
        for request in [add, update] {
            do { _ = try await runtime.perform(request); XCTFail("Paused bookmark mutation") } catch {}
        }
        var remove = BrowserRequest(.bookmarkRemove, browserID: a.id); remove.bookmarkID = bookmark.id
        do { _ = try await runtime.perform(remove); XCTFail("Paused bookmark removal") } catch {}
        let saved = try await runtime.perform(.init(.bookmarks, browserID: a.id))
        XCTAssertEqual(saved.totalCount, 1); XCTAssertEqual(saved.limit, 50); XCTAssertEqual(saved.offset, 0)
        let visits = try await runtime.perform(.init(.history, browserID: a.id))
        XCTAssertEqual(visits.history?.first?.title, "Visited")
        try runtime.setPaused(false, browserID: a.id)
        _ = try await runtime.perform(remove)
        let empty = try await runtime.perform(.init(.bookmarks, browserID: a.id)); XCTAssertEqual(empty.totalCount, 0)
    }
    @MainActor func testPauseAndTabOwnership() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root)
        var a = try library.create(name: "A"), b = try library.create(name: "B")
        a.tabs = [.init()]; try library.update(a)
        let runtime = BrowserRuntime(library: library)
        do { _ = try runtime.tab(browserID: b.id, tabID: a.tabs[0].id); XCTFail("Cross-profile access") } catch {}
        try runtime.setPaused(true, browserID: a.id)
        do { _ = try await runtime.perform(.init(.open, browserID: a.id)); XCTFail("Paused browser opened") } catch {}
        let response = try await runtime.perform(.init(.status, browserID: a.id))
        XCTAssertEqual(response.browser?.paused, true)
        XCTAssertEqual(response.tabs?.first?.id, a.tabs[0].id)
        var download = BrowserRequest(.download, browserID: b.id); download.fileID = UUID()
        do { _ = try await runtime.perform(download); XCTFail("Unknown download") } catch {}
    }
}
