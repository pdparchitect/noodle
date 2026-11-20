import NoodleCore
import XCTest
@testable import NoodleContextFieldsTools

final class ContextFieldsToolProviderTests: XCTestCase {
    /// Stands in for another app's fields, so these tests need no Accessibility, no app and no screen.
    private final class FakeSurface: ContextFieldSurface, @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: String]
        /// Fields that take nothing written to them, as Chrome's date fields do.
        var stubborn: Set<String> = []
        private(set) var writes: [(field: String, text: String)] = []
        private(set) var presses: [String] = []
        private(set) var choices: [(field: String, option: String)] = []
        /// A radio button pressed on turns the others in its group off.
        var group: [String] = []

        init(_ values: [String: String]) { self.values = values }
        func set(_ field: String, _ value: String?) { lock.withLock { values[field] = value } }
        func value(of field: String) async -> String? { lock.withLock { values[field] } }
        func setText(_ text: String, of field: String) async {
            lock.withLock { writes.append((field, text)); if !stubborn.contains(field) { values[field] = text } }
        }
        func press(_ field: String) async {
            lock.withLock {
                presses.append(field)
                guard !stubborn.contains(field) else { return }
                if group.contains(field) { for other in group { values[other] = "false" }; values[field] = "true" }
                else { values[field] = values[field] == "true" ? "false" : "true" }
            }
        }
        func choose(_ option: String, in field: String) async {
            lock.withLock { choices.append((field, option)); if !stubborn.contains(field) { values[field] = option } }
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { current } }
        private var issued = 0
        func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
        func nextToken() -> String { lock.withLock { issued += 1; return "token-\(issued)" } }
    }

    private let alice = UUID(), bob = UUID(), carol = UUID()
    private let attachment = UUID()
    private var clock: Clock!
    private var grants: ContextFieldGrants!
    private var registry: ToolProviderRegistry!
    private var surface: FakeSurface!

    private let fields = [
        ContextField(id: "f1", label: "Full name", kind: .text, value: ""),
        ContextField(id: "f2", label: "Delivery notes", kind: .text, value: "Leave at door."),
        ContextField(id: "f3", label: "Send me news", kind: .checkbox, value: "false"),
        ContextField(id: "f4", label: "Standard", kind: .radio, value: "true"),
        ContextField(id: "f5", label: "Express", kind: .radio, value: "false"),
        ContextField(id: "f6", label: "Country", kind: .choice, value: "United Kingdom", options: ["United Kingdom", "Germany"]),
        ContextField(id: "f7", label: "Delivery date", kind: .date, value: ""),
        ContextField(id: "f8", label: "Size", kind: .choice, value: "M"),
    ]

    override func setUpWithError() throws {
        let clock = Clock()
        self.clock = clock
        grants = ContextFieldGrants(now: { clock.now }, token: { clock.nextToken() })
        surface = FakeSurface(Dictionary(uniqueKeysWithValues: fields.map { ($0.id, $0.value ?? "") }))
        surface.group = ["f4", "f5"]
        registry = ToolProviderRegistry()
        try registry.register(ContextFieldsToolProvider(grants: grants))
    }

    private func stageAndSend(to agents: [UUID]) {
        grants.stage(ContextFieldCapture(app: "Google Chrome", window: "Checkout", page: "https://shop.example/checkout",
                                         fields: fields, withheld: ["Card number", "CVC"], surface: surface), attachment: attachment)
        grants.grant(attachments: [attachment], to: agents)
    }

    private func call(_ tool: String, _ arguments: [String: Any], as agent: UUID) async throws -> [String: Any] {
        let request = ToolBridgeRequest(session: "s", action: .call, provider: "context-fields", tool: tool,
                                        arguments: try JSONSerialization.data(withJSONObject: arguments))
        let data = try await ToolBroker.perform(request, registry: registry, assignments: { .none },
                                                context: ToolCallContext(agentID: agent, workspace: URL(fileURLWithPath: "/")))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func value(_ field: String) async -> String? { await surface.value(of: field) }
    private func captures(_ agent: UUID) async throws -> [[String: Any]] {
        let result = try await call("list", [:], as: agent)
        XCTAssertNotEqual(result["isError"] as? Bool, true)
        return try XCTUnwrap((result["structuredContent"] as? [String: Any])?["captures"] as? [[String: Any]])
    }
    private func token(_ agent: UUID) async throws -> String {
        let listed = try await captures(agent); return try XCTUnwrap(listed.first?["token"] as? String)
    }
    private func write(_ token: String, _ edits: [[String: Any]], as agent: UUID) async throws -> (error: Bool, text: String, fields: [String: String]) {
        let result = try await call("write", ["token": token, "fields": edits], as: agent)
        let text = ((result["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        let outcomes = ((result["structuredContent"] as? [String: Any])?["fields"] as? [[String: Any]]) ?? []
        return (result["isError"] as? Bool == true, text,
                Dictionary(uniqueKeysWithValues: outcomes.map { ($0["id"] as? String ?? "", $0["result"] as? String ?? "") }))
    }

    func testEveryBotIsAlwaysOfferedTheToolWithoutAnAssignment() throws {
        let provider = ContextFieldsToolProvider(grants: grants)
        XCTAssertNoThrow(try provider.manifest.validate())
        XCTAssertEqual(provider.manifest.id, "context-fields")
        XCTAssertEqual(provider.kind, .builtIn)
        XCTAssertEqual(provider.manifest.activation, .always)
    }

    /// Each bot the context went to holds its own token, and no bot can use another's.
    func testEachRecipientGetsItsOwnTokenThatNoOtherBotCanUse() async throws {
        stageAndSend(to: [alice, bob])
        let aliceToken = try await token(alice), bobToken = try await token(bob)
        XCTAssertNotEqual(aliceToken, bobToken)
        let listed = try await captures(alice)
        XCTAssertEqual(listed.count, 1)
        XCTAssertEqual(listed.first?["app"] as? String, "Google Chrome")
        XCTAssertEqual(listed.first?["page"] as? String, "https://shop.example/checkout")
        XCTAssertEqual((listed.first?["fields"] as? [[String: Any]])?.map { $0["label"] as? String }, fields.map(\.label))
        XCTAssertEqual(listed.first?["withheld"] as? [String], ["Card number", "CVC"], "the bot hears which fields were left out")

        do { let none = try await captures(carol); XCTAssertTrue(none.isEmpty, "a bot the context was not sent to has nothing") }
        let stolen = try await write(aliceToken, [["id": "f1", "value": "Mallory"]], as: bob)
        XCTAssertTrue(stolen.error)
        let stranger = try await write(aliceToken, [["id": "f1", "value": "Mallory"]], as: carol)
        XCTAssertTrue(stranger.error)
        XCTAssertTrue(surface.writes.isEmpty)
    }

    /// Context that was only staged gives nothing; the token's fifteen minutes start when it is sent.
    func testTokensLiveFifteenMinutesFromSending() async throws {
        grants.stage(ContextFieldCapture(app: "Google Chrome", window: nil, page: nil, fields: fields, surface: surface), attachment: attachment)
        do { let none = try await captures(alice); XCTAssertTrue(none.isEmpty, "staged, not sent") }
        clock.advance(10 * 60)
        grants.grant(attachments: [attachment], to: [alice])
        let token = try await token(alice)
        clock.advance(14 * 60)
        let early = try await write(token, [["id": "f1", "value": "Ada"]], as: alice)
        XCTAssertFalse(early.error, early.text)
        XCTAssertEqual(early.fields["f1"], "written")
        clock.advance(61)
        do { let none = try await captures(alice); XCTAssertTrue(none.isEmpty) }
        let late = try await write(token, [["id": "f1", "value": "Ada Lovelace"]], as: alice)
        XCTAssertTrue(late.error)
        XCTAssertEqual(surface.writes.count, 1)
    }

    /// Context left unsent for fifteen minutes is dropped, and a capture is granted only once.
    func testUnsentContextExpiresAndIsGrantedOnce() async throws {
        grants.stage(ContextFieldCapture(app: "TextEdit", window: nil, page: nil, fields: fields, surface: surface), attachment: attachment)
        clock.advance(15 * 60 + 1)
        grants.grant(attachments: [attachment], to: [alice])
        do { let none = try await captures(alice); XCTAssertTrue(none.isEmpty) }

        let again = UUID()
        grants.stage(ContextFieldCapture(app: "TextEdit", window: nil, page: nil, fields: fields, surface: surface), attachment: again)
        grants.grant(attachments: [again], to: [alice])
        grants.grant(attachments: [again], to: [bob])
        do { let some = try await captures(alice); XCTAssertEqual(some.count, 1) }
        do { let none = try await captures(bob); XCTAssertTrue(none.isEmpty, "a resend or forward of the same attachment grants nothing more") }
    }

    /// Replace and append on text fields; a later write by the same bot builds on what it wrote.
    func testReplaceAndAppendText() async throws {
        stageAndSend(to: [alice])
        let token = try await token(alice)
        let first = try await write(token, [["id": "f1", "value": "Ada Lovelace"],
                                            ["id": "f2", "value": " Ring twice.", "mode": "append"]], as: alice)
        XCTAssertEqual(first.fields, ["f1": "written", "f2": "written"])
        let f1Value = await value("f1"); XCTAssertEqual(f1Value, "Ada Lovelace")
        let f2Value = await value("f2"); XCTAssertEqual(f2Value, "Leave at door. Ring twice.")
        let second = try await write(token, [["id": "f2", "value": " Thanks!", "mode": "append"]], as: alice)
        XCTAssertEqual(second.fields["f2"], "written")
        let f2Again = await value("f2"); XCTAssertEqual(f2Again, "Leave at door. Ring twice. Thanks!")
    }

    /// A field the person changed since the capture is left alone; the others are still written.
    func testAFieldThePersonEditedIsNeverOverwritten() async throws {
        stageAndSend(to: [alice])
        let token = try await token(alice)
        surface.set("f1", "Typed by the person")
        let result = try await write(token, [["id": "f1", "value": "Ada"], ["id": "f2", "value": "Back door."]], as: alice)
        XCTAssertEqual(result.fields, ["f1": "changed", "f2": "written"])
        let f1Value = await value("f1"); XCTAssertEqual(f1Value, "Typed by the person")
        XCTAssertTrue(result.text.contains("Full name"), result.text)
    }

    /// Checkboxes and radio buttons are pressed only when that changes them; options must be offered ones.
    func testTogglesAndChoices() async throws {
        stageAndSend(to: [alice])
        let token = try await token(alice)
        let result = try await write(token, [["id": "f3", "value": "true"], ["id": "f4", "value": "true"],
                                             ["id": "f5", "value": "true"], ["id": "f6", "value": "Germany"]], as: alice)
        XCTAssertEqual(result.fields, ["f3": "written", "f4": "unchanged", "f5": "written", "f6": "written"])
        XCTAssertEqual(surface.presses, ["f3", "f5"])
        let f4Value = await value("f4"); XCTAssertEqual(f4Value, "false")
        XCTAssertEqual(surface.choices.map(\.option), ["Germany"])

        let wrong = try await write(token, [["id": "f6", "value": "Atlantis"], ["id": "f5", "value": "false"],
                                            ["id": "f3", "value": "maybe"]], as: alice)
        XCTAssertEqual(wrong.fields, ["f6": "invalid", "f5": "invalid", "f3": "invalid"])
        XCTAssertEqual(surface.choices.count, 1)
        XCTAssertEqual(surface.presses.count, 2)
    }

    /// What does not take is reported, not claimed: date fields, a write that reads back different, a field gone.
    func testWhatDidNotTakeIsReported() async throws {
        stageAndSend(to: [alice])
        let token = try await token(alice)
        surface.stubborn = ["f1"]
        surface.set("f2", nil)
        let result = try await write(token, [["id": "f7", "value": "2026-12-24"], ["id": "f1", "value": "Ada"],
                                             ["id": "f2", "value": "x"], ["id": "nope", "value": "x"],
                                             ["id": "f3", "value": "true", "mode": "append"]], as: alice)
        XCTAssertEqual(result.fields, ["f7": "not-filled", "f1": "unconfirmed", "f2": "gone", "nope": "invalid", "f3": "invalid"])
        XCTAssertFalse(surface.writes.contains { $0.field == "f7" }, "a date field is never touched")
        XCTAssertTrue(result.text.contains("Delivery date"), result.text)
    }

    /// A browser lists a menu's options only while it is open, so a choice may come without them;
    /// then any option is tried and reading it back says whether it took.
    func testAChoiceWithoutKnownOptionsIsJudgedByReadingItBack() async throws {
        stageAndSend(to: [alice])
        let token = try await token(alice)
        let first = try await write(token, [["id": "f8", "value": "L"]], as: alice)
        XCTAssertEqual(first.fields["f8"], "written")
        surface.stubborn = ["f8"]
        let second = try await write(token, [["id": "f8", "value": "XXL"]], as: alice)
        XCTAssertEqual(second.fields["f8"], "not-filled")
        XCTAssertEqual(surface.choices.map(\.option), ["L", "XXL"])
    }

    /// A page in a hidden tab can take text yet show it only later. The bot hears it is unconfirmed, and
    /// whichever of the two the field then holds is Noodle's doing, so a later write is not refused.
    func testTextThatShowsLateIsUnconfirmedAndStillNoodles() async throws {
        stageAndSend(to: [alice])
        let token = try await token(alice)
        surface.stubborn = ["f2"]
        let first = try await write(token, [["id": "f2", "value": "Back door."]], as: alice)
        XCTAssertEqual(first.fields["f2"], "unconfirmed")
        XCTAssertTrue(first.text.contains("Delivery notes"), first.text)
        surface.stubborn = []
        surface.set("f2", "Back door.")
        let second = try await write(token, [["id": "f2", "value": " Ring twice.", "mode": "append"]], as: alice)
        XCTAssertEqual(second.fields["f2"], "written")
        let f2Value = await value("f2"); XCTAssertEqual(f2Value, "Back door. Ring twice.")
        surface.set("f2", "Leave at door.")
        let third = try await write(token, [["id": "f2", "value": "Side gate."]], as: alice)
        XCTAssertEqual(third.fields["f2"], "changed", "the old text is no longer Noodle's once a write was confirmed")
    }
}
