import BrowserBridge
import BrowserCore
import BrowserExternal
import NoodleSettingsUI
@testable import NoodleBrowser
import XCTest

@MainActor private final class Answers: ExternalPrompting {
    var approve = true
    var pick: ((([ExternalItem]) -> UUID?))?
    var confirm = true
    var asked: [String] = []
    func approve(_ launcher: ExternalLauncher) async -> Bool { asked.append("approve"); return approve }
    func pick(_ launcher: ExternalLauncher, from items: [ExternalItem]) async -> UUID? {
        asked.append("pick " + items.map(\.name).sorted().joined(separator: ",")); return pick?(items)
    }
    func confirm(_ launcher: ExternalLauncher, message: String, action: String) async -> Bool { asked.append("confirm"); return confirm }
}

private let claude = ExternalLauncher(key: "team:Q6L2SF6YDW:com.anthropic.claude-code", name: "Claude Code", path: "/c")
private let codex = ExternalLauncher(key: "team:2DC432GLL2:com.openai.codex", name: "Codex", path: "/x")

final class BrowserExternalRuntimeTests: XCTestCase {
    private var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    @MainActor private func runtime(_ answers: Answers, enabled: Bool = true) -> (BrowserRuntime, BrowserLibrary) {
        let library = BrowserLibrary(root: root)
        let gate = ExternalGate(url: nil, prompter: answers)
        gate.enabled = enabled
        let runtime = BrowserRuntime(library: library, transferRoot: root, external: gate)
        return (runtime, library)
    }

    @MainActor private func create(_ runtime: BrowserRuntime, _ name: String, as launcher: ExternalLauncher = claude) async throws -> RemoteBrowser {
        var request = BrowserRequest(.create); request.profile = BrowserDraft(name: name)
        let response = try await runtime.performExternal(request, launcher: launcher)
        return try XCTUnwrap(response.browser)
    }

    @MainActor func testNothingIsServedWhileExternalToolsAreOff() async throws {
        let answers = Answers()
        let (runtime, library) = runtime(answers, enabled: false)
        do { _ = try await runtime.performExternal(.init(.list), launcher: claude); XCTFail("Served while off") } catch {}
        XCTAssertTrue(answers.asked.isEmpty)
        XCTAssertTrue(library.profiles.isEmpty)
    }

    @MainActor func testCallersListOnlyWhatTheyMadeOrBorrowed() async throws {
        let answers = Answers()
        let (runtime, library) = runtime(answers)
        let personal = try library.create(name: "Personal")
        var hub = try library.create(name: "Hub's"); hub.hub = true; try library.update(hub)
        let made = try await create(runtime, "Research")
        let claudeList = try await runtime.performExternal(.init(.list), launcher: claude)
        XCTAssertEqual(claudeList.browsers?.map(\.id), [made.id])
        let codexList = try await runtime.performExternal(.init(.list), launcher: codex)
        XCTAssertEqual(codexList.browsers?.map(\.id), [])
        answers.pick = { items in items.first { $0.name == "Personal" }?.id }
        let lent = try await runtime.performExternal(.init(.borrow), launcher: claude).browser
        XCTAssertEqual(lent?.id, personal.id)
        // The Hub's browsers are never offered; what the caller has is not offered again.
        XCTAssertEqual(answers.asked.last, "pick Personal")
        let after = try await runtime.performExternal(.init(.list), launcher: claude)
        XCTAssertEqual(Set(after.browsers?.map(\.id) ?? []), [made.id, personal.id])
    }

    @MainActor func testBrowsersNotLentCannotBeUsed() async throws {
        let answers = Answers()
        let (runtime, library) = runtime(answers)
        let personal = try library.create(name: "Personal")
        _ = try await create(runtime, "Mine")
        for operation: BrowserOperation in [.status, .tabs, .history, .open] {
            do { _ = try await runtime.performExternal(.init(operation, browserID: personal.id), launcher: claude); XCTFail("\(operation) on a browser not lent") } catch {}
        }
        var hub = try library.create(name: "Hub's"); hub.hub = true; try library.update(hub)
        runtime.external?.setAccess(true, to: hub.id, for: runtime.external!.grants.callers[0].id)
        do { _ = try await runtime.performExternal(.init(.status, browserID: hub.id), launcher: claude); XCTFail("Used the Hub's browser") } catch {}
    }

    @MainActor func testOnlyBrowsersACallerMadeCanBeChangedOrDeleted() async throws {
        let answers = Answers()
        let (runtime, library) = runtime(answers)
        let personal = try library.create(name: "Personal")
        let made = try await create(runtime, "Mine")
        answers.pick = { _ in personal.id }
        _ = try await runtime.performExternal(.init(.borrow), launcher: claude)
        var rename = BrowserRequest(.update, browserID: personal.id); rename.profile = BrowserDraft(name: "Taken")
        do { _ = try await runtime.performExternal(rename, launcher: claude); XCTFail("Renamed a lent browser") } catch {}
        do { _ = try await runtime.performExternal(.init(.delete, browserID: personal.id), launcher: claude); XCTFail("Deleted a lent browser") } catch {}
        XCTAssertEqual(try library.profile(personal.id).name, "Personal")
        rename.browserID = made.id
        _ = try await runtime.performExternal(rename, launcher: claude)
        XCTAssertEqual(try library.profile(made.id).name, "Taken")
        _ = try await runtime.performExternal(.init(.delete, browserID: made.id), launcher: claude)
        XCTAssertNil(library.profiles.first { $0.id == made.id })
        XCTAssertFalse(runtime.external!.allows(runtime.external!.grants.callers[0].id, made.id))
    }

    @MainActor func testWhatNoodleAndTheHubAloneDoIsRefused() async throws {
        let answers = Answers()
        let (runtime, _) = runtime(answers)
        let made = try await create(runtime, "Mine")
        var owner = BrowserRequest(.setOwner, browserID: made.id); owner.owner = BrowserOwner(id: UUID(), name: "Eve")
        for request in [owner, BrowserRequest(.surfaceStream, browserID: made.id), BrowserRequest(.present, browserID: made.id, tabID: UUID())] {
            do { _ = try await runtime.performExternal(request, launcher: claude); XCTFail("\(request.operation) served") } catch {}
        }
    }

    @MainActor func testMakingManyBrowsersAsksFirst() async throws {
        let answers = Answers()
        let (runtime, library) = runtime(answers)
        for index in 0..<BrowserRuntime.externalCreationLimit { _ = try await create(runtime, "B\(index)") }
        XCTAssertFalse(answers.asked.contains("confirm"))
        _ = try await create(runtime, "One more")
        XCTAssertEqual(answers.asked.filter { $0 == "confirm" }.count, 1)
        XCTAssertEqual(library.profiles.count, BrowserRuntime.externalCreationLimit + 1)
        answers.confirm = false
        do { _ = try await create(runtime, "Another"); XCTFail("Made past the limit after a no") } catch {}
        XCTAssertEqual(library.profiles.count, BrowserRuntime.externalCreationLimit + 1)
        // Asked again straight away, the person is not bothered and nothing is made.
        answers.confirm = true
        do { _ = try await create(runtime, "Again"); XCTFail("Asked again straight after a no") } catch {}
        XCTAssertEqual(answers.asked.filter { $0 == "confirm" }.count, 2)
        XCTAssertEqual(library.profiles.count, BrowserRuntime.externalCreationLimit + 1)
    }

    @MainActor func testATabCanBeLeftOutForTheSelectedOne() async throws {
        let answers = Answers()
        let (runtime, _) = runtime(answers)
        let made = try await create(runtime, "Mine")
        let opened = try await runtime.performExternal(.init(.open, browserID: made.id), launcher: claude)
        let tab = try XCTUnwrap(opened.tabID)
        let reset = try await runtime.performExternal(.init(.mouseReset, browserID: made.id), launcher: claude)
        XCTAssertEqual(reset.tabID, tab)
        runtime.shutdown()
    }

    /// Borrowing belongs to the external connection; Noodle or the Hub asking for it is refused, not a crash.
    @MainActor func testBorrowingOverTheCompanionConnectionIsRefused() async throws {
        let (runtime, _) = runtime(Answers())
        for caller in [BrowserBuildIdentity.current.noodleID, BrowserBuildIdentity.current.hubID] {
            do { _ = try await runtime.perform(.init(.borrow), caller: caller); XCTFail("Borrowed over the companion connection") } catch {}
        }
    }

    @MainActor func testBrowsersDeletedInTheAppAreForgotten() async throws {
        let answers = Answers()
        let (runtime, _) = runtime(answers)
        let made = try await create(runtime, "Mine")
        try await runtime.removeBrowser(made.id)
        XCTAssertTrue(runtime.external!.grants.callers[0].resources.isEmpty)
    }
}

final class BrowserSidebarSectionTests: XCTestCase {
    /// Browsers an outside app made are listed apart; ones it borrowed stay the person's own. The Hub's are in its own space.
    @MainActor func testBrowsersOutsideAppsMadeAreListedUnderExternalTools() {
        let own = BrowserProfile(name: "Own"), made = BrowserProfile(name: "Made"), lent = BrowserProfile(name: "Lent")
        var hub = BrowserProfile(name: "Hub's"); hub.hub = true
        let sections = BrowserLibraryView.sidebar([own, made, lent, hub], created: [made.id], space: .personal)
        XCTAssertEqual(sections.map(\.title), ["Browsers", "Agents"])
        XCTAssertEqual(sections.map { $0.profiles.map(\.name) }, [["Own", "Lent"], ["Made"]])
        XCTAssertEqual(BrowserLibraryView.sidebar([own], created: [], space: .personal).map(\.title), ["Browsers"])
    }

    /// The Hub's space has a section for each person, then the browsers kept for no one.
    @MainActor func testTheHubsSpaceListsItsBrowsersByPerson() {
        let ada = BrowserOwner(id: UUID(), name: "Ada")
        func profile(_ name: String, _ owner: BrowserOwner?) -> BrowserProfile {
            var profile = BrowserProfile(name: name); profile.hub = true; profile.hubOwner = owner
            return profile
        }
        let sections = BrowserLibraryView.sidebar([BrowserProfile(name: "Own"), profile("Work", ada), profile("Loose", nil)], created: [], space: .hub)
        XCTAssertEqual(sections.map(\.title), ["Ada", "Other"])
        XCTAssertEqual(sections.map { $0.profiles.map(\.name) }, [["Work"], ["Loose"]])
    }
}
