import BrowserBridge
import BrowserCore
@testable import NoodleBrowser
import XCTest

final class BrowserRuntimeTests: XCTestCase {
    @MainActor func testBrowsersTheHubMakesOrUsesAreListedAsHub() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), identity = BrowserBuildIdentity.current
        let runtime = BrowserRuntime(library: library)
        var create = BrowserRequest(.create); create.profile = BrowserDraft(name: "Hub made")
        let made = try await runtime.perform(create, caller: identity.hubID).browser!
        XCTAssertEqual(try library.profile(made.id).hub, true)
        let own = try await runtime.perform(create, caller: identity.noodleID).browser!
        XCTAssertNil(try library.profile(own.id).hub)
        // Made by the Hub before it said so: the Hub only ever uses its own.
        let earlier = try library.create(name: "Earlier")
        _ = try await runtime.perform(.init(.bookmarks, browserID: earlier.id), caller: identity.noodleID)
        XCTAssertNil(try library.profile(earlier.id).hub)
        _ = try await runtime.perform(.init(.bookmarks, browserID: earlier.id), caller: identity.hubID)
        XCTAssertEqual(try library.profile(earlier.id).hub, true)
    }
    @MainActor func testOnlyTheHubSaysWhomABrowserIsKeptFor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), identity = BrowserBuildIdentity.current
        let runtime = BrowserRuntime(library: library), made = try library.create(name: "Work")
        var set = BrowserRequest(.setOwner, browserID: made.id)
        set.owner = BrowserOwner(id: UUID(), name: "Eve")
        do { _ = try await runtime.perform(set, caller: identity.noodleID); XCTFail("Noodle said whom a browser is for") } catch {}
        XCTAssertNil(try library.profile(made.id).hubOwner)
        let ada = BrowserOwner(id: UUID(), name: "Ada")
        set.owner = ada
        _ = try await runtime.perform(set, caller: identity.hubID)
        XCTAssertEqual(try library.profile(made.id).hubOwner, ada)
        let listed = try await runtime.perform(.init(.list), caller: identity.hubID).browsers
        XCTAssertEqual(listed?.first?.owner, ada)
        set.owner = nil
        _ = try await runtime.perform(set, caller: identity.hubID)
        XCTAssertNil(try library.profile(made.id).hubOwner)
    }
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
    @MainActor func testTabsNobodyUsedForTheExpiryAreClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), now = Date(), day: TimeInterval = 86_400
        var a = try library.create(name: "A")
        let old = BrowserTabInfo(lastUsed: now - 8 * day), recent = BrowserTabInfo(lastUsed: now - day), unknown = BrowserTabInfo()
        a.tabs = [old, recent, unknown]; a.selectedTabID = old.id; try library.update(a)
        let runtime = BrowserRuntime(library: library)
        runtime.expireTabs(unusedFor: 7 * day, now: now)
        let tabs = try library.profile(a.id).tabs
        XCTAssertEqual(tabs.map(\.id), [recent.id, unknown.id])
        XCTAssertEqual(try library.profile(a.id).selectedTabID, recent.id)
        // A tab with no record of use has its time start now rather than being closed.
        XCTAssertEqual(tabs.last?.lastUsed, now)
        runtime.expireTabs(unusedFor: 7 * day, now: now + 6.5 * day)
        XCTAssertEqual(try library.profile(a.id).tabs.map(\.id), [unknown.id])
    }
    @MainActor func testPeopleBotsAndLiveViewersUsingATabKeepItOpen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = BrowserLibrary(root: root), long = Date() - 30 * 86_400
        var a = try library.create(name: "A")
        let first = BrowserTabInfo(lastUsed: long), second = BrowserTabInfo(lastUsed: long), third = BrowserTabInfo(lastUsed: long)
        a.tabs = [first, second, third]; a.selectedTabID = first.id; try library.update(a)
        let runtime = BrowserRuntime(library: library)
        defer { runtime.shutdown() }
        func used(_ id: UUID) throws -> Date { try XCTUnwrap(library.profile(a.id).tabs.first { $0.id == id }?.lastUsed) }
        // A bot.
        var reload = BrowserRequest(.reload, browserID: a.id); reload.tabID = first.id
        _ = try await runtime.perform(reload)
        XCTAssertGreaterThan(try used(first.id), long)
        // A person choosing a tab.
        try runtime.selectTab(browserID: a.id, tabID: second.id)
        XCTAssertGreaterThan(try used(second.id), long)
        // Someone watching live, acting on the selected tab.
        try runtime.selectTab(browserID: a.id, tabID: third.id)
        var profile = try library.profile(a.id)
        profile.tabs[2].lastUsed = long; try library.update(profile)
        runtime.tabs[third.id]?.info.lastUsed = long
        try BrowserLiveView(browserID: a.id, runtime: runtime).apply(.scroll(x: 10, y: 400, dx: 0, dy: 10))
        XCTAssertGreaterThan(try used(third.id), long)
        // A new tab starts as used.
        let opened = try await runtime.perform(.init(.open, browserID: a.id))
        XCTAssertNotNil(try used(XCTUnwrap(opened.tabID)))
    }

    /// A long home folder name must not push the connection past the platform's socket path limit.
    func testLongConnectionPathRegistersAndAnswers() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(String(repeating: "x", count: 110))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("b.sock")
        let server = try BrowserConnectionServer(socket: url, team: "1234567890") { _, _ in .init() }
        XCTAssertThrowsError(try BrowserConnectionServer(socket: url, team: "1234567890") { _, _ in .init() }) {
            XCTAssertEqual($0.localizedDescription, "A browser provider is already running.")
        }
        withExtendedLifetime(server) {}
    }
}
