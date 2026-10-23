import MailBridge
import NoodleCore
import XCTest
@testable import NoodleMailTools

final class MailToolProviderTests: XCTestCase {
    private final class Transport: @unchecked Sendable {
        var requests: [MailRequest] = []
        var respond: (MailRequest) throws -> MailResponse = { _ in MailResponse() }
    }
    /// The bot's live assignments, which a test may change while a call runs.
    private final class Assigned: @unchecked Sendable { var ids: Set<String> = [] }
    private let mine = UUID(), secret = UUID()
    private var root: URL!
    private var transport: Transport!
    private var assigned: Assigned!
    private var provider: MailToolProvider!
    private let registry = ToolProviderRegistry()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let transport = Transport()
        self.transport = transport
        assigned = Assigned(); assigned.ids = [mine.uuidString]
        provider = MailToolProvider { request in
            transport.requests.append(request)
            return try transport.respond(request)
        }
        try registry.register(provider)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    /// The bytes the broker returns for a call, exactly as the bot's command line receives them.
    private func raw(_ tool: String, _ arguments: [String: Any]) async throws -> Data {
        let request = ToolBridgeRequest(session: "s", action: .call, provider: provider.manifest.id, tool: tool,
                                        arguments: try JSONSerialization.data(withJSONObject: arguments))
        return try await ToolBroker.perform(request, registry: registry, assignments: { [assigned] in ["mailbox": assigned!.ids] },
                                            context: ToolCallContext(agentID: UUID(), workspace: root),
                                            host: ToolHostServices(isMember: { _, _ in false }, post: { _, _, _ in UUID() }))
    }
    private func call(_ tool: String, _ arguments: [String: Any]) async throws -> [String: Any] {
        let data = try await raw(tool, arguments)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func structured(_ result: [String: Any]) -> [String: Any] { result["structuredContent"] as? [String: Any] ?? [:] }
    private func text(_ result: [String: Any]) -> String? { ((result["content"] as? [[String: Any]])?.first)?["text"] as? String }

    /// Every operation is a tool, bound to an assigned mailbox or listing them for the broker to filter.
    func testEveryOperationIsAToolBoundToAnAssignedMailbox() async throws {
        XCTAssertNoThrow(try provider.manifest.validate())
        XCTAssertEqual(provider.manifest.activation, .whenAssigned("mailbox"))
        let tools = try ToolDescriptor.list(mcp: try await provider.tools(context: .init(agentID: UUID(), workspace: root)))
        XCTAssertEqual(Set(tools.map(\.name)), Set(MailOperation.allCases.map(\.rawValue)))
        for tool in tools {
            XCTAssertFalse(tool.description.isEmpty, tool.name)
            if tool.name == "mailboxes" { XCTAssertEqual(tool.resourceList, ToolResourceList(kind: "mailbox", path: "mailboxes")) }
            else { XCTAssertEqual(tool.resourceParameters, [ToolResourceParameter(name: "mailbox", kind: "mailbox")], tool.name) }
        }
        XCTAssertEqual(tools.first { $0.name == "attachment" }?.fileParameters, [ToolFileParameter(name: "output", access: .write)])
    }

    /// An unassigned or missing mailbox never reaches Noodle Mail, and the mailbox list shows only assigned ones.
    func testUnassignedMailboxesNeverReachTheSocketAndListsAreFiltered() async throws {
        do { _ = try await call("folders", ["mailbox": secret.uuidString]); XCTFail("Expected a refusal.") } catch {}
        do { _ = try await call("list", [:]); XCTFail("Expected a refusal.") } catch {}
        XCTAssertTrue(transport.requests.isEmpty)
        transport.respond = { [mine, secret] _ in
            var response = MailResponse()
            response.mailboxes = [RemoteMailbox(id: mine, name: "Work", address: "work@mail.example.org"),
                                  RemoteMailbox(id: secret, name: "Private", address: "someone@example.com")]
            return response
        }
        let result = try await call("mailboxes", [:])
        let rows = structured(result)["mailboxes"] as? [[String: Any]]
        XCTAssertEqual(rows?.compactMap { $0["name"] as? String }, ["Work"])
        XCTAssertFalse(String(describing: result["content"]).contains("Private"))
    }

    /// Losing the assignment while a call runs withholds its result.
    func testRevokingAMailboxDuringACallWithholdsTheResult() async throws {
        transport.respond = { [assigned] _ in
            assigned!.ids = []
            var response = MailResponse(); response.folders = [MailFolderInfo(name: "INBOX", display: "INBOX", role: "inbox")]
            return response
        }
        do { _ = try await call("folders", ["mailbox": mine.uuidString]); XCTFail("Expected the result to be withheld.") } catch {}
    }

    /// Arguments become exactly the request Noodle Mail receives.
    func testArgumentsBecomeTheRequest() async throws {
        _ = try await call("search", ["mailbox": mine.uuidString, "folder": "Odeslan&AOk-", "from": "ada", "since": "2026-10-01",
                                      "before": "2026-10-02", "unread": true, "limit": 5, "before_uid": 900])
        let search = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(search.operation, .search)
        XCTAssertEqual(search.mailboxID, mine)
        XCTAssertEqual(search.folder, "Odeslan&AOk-")
        XCTAssertEqual(search.query?.from, "ada")
        XCTAssertEqual(search.query?.since, "2026-10-01")
        XCTAssertEqual(search.query?.before, "2026-10-02")
        XCTAssertEqual(search.query?.unreadOnly, true)
        XCTAssertEqual(search.query?.limit, 5)
        XCTAssertEqual(search.query?.beforeUID, 900)
        _ = try await call("read", ["mailbox": mine.uuidString, "uid": 7, "mark_read": true, "max_chars": 5_000])
        let read = try XCTUnwrap(transport.requests.last)
        XCTAssertEqual(read.uid, 7)
        XCTAssertEqual(read.markRead, true)
        XCTAssertEqual(read.maxCharacters, 5_000)
    }

    /// Stands in for Noodle's checkpoint: counts the questions, and notes how many requests had reached Noodle Mail at each.
    private final class Checkpoint: @unchecked Sendable {
        var asked = 0
        var requestsAlreadySent: [Int] = []
    }
    /// A call straight to the provider, so a test supplies the `authorize` that the broker would otherwise build.
    private func direct(_ tool: String, _ arguments: [String: Any], authorize: @escaping @Sendable () async throws -> Void) async throws -> [String: Any] {
        let context = ToolCallContext(agentID: UUID(), workspace: root, authorize: authorize)
        let data = try await provider.call(tool, arguments: try JSONSerialization.data(withJSONObject: arguments), files: [], context: context)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func respondWithAMessage() {
        transport.respond = { _ in
            var response = MailResponse()
            response.message = MailMessage(uid: 7, from: "ada", to: ["work@mail.example.org"], cc: [], date: nil, subject: "Invoice", messageId: nil,
                                           text: "Hello", truncated: false, attachments: [])
            return response
        }
    }

    /// Marking a message read changes the server, so Noodle is asked once, right before the read leaves: the mailbox list, which
    /// changes nothing, goes first, so the seconds Noodle Mail may take to start pass before Noodle is asked, not after.
    func testMarkingReadAsksNoodleRightBeforeTheRead() async throws {
        respondWithAMessage()
        let checkpoint = Checkpoint(), transport = transport!
        let result = try await direct("read", ["mailbox": mine.uuidString, "uid": 7, "mark_read": true]) {
            checkpoint.asked += 1
            checkpoint.requestsAlreadySent.append(transport.requests.count)
        }
        XCTAssertEqual(result["isError"] as? Bool, false, String(describing: result["content"]))
        XCTAssertEqual(checkpoint.asked, 1)
        XCTAssertEqual(transport.requests.map(\.operation), [.mailboxes, .read])
        XCTAssertEqual(checkpoint.requestsAlreadySent, [1], "only the mailbox list had gone out when Noodle was asked")
        XCTAssertEqual(transport.requests.last?.markRead, true)
    }

    /// If Noodle refuses the checkpoint, the message is not marked read: the read never reaches Noodle Mail.
    func testARevokedMarkReadNeverReachesTheApp() async throws {
        respondWithAMessage()
        let result = try await direct("read", ["mailbox": mine.uuidString, "uid": 7, "mark_read": true]) {
            throw ToolProviderError("This call is no longer allowed.")
        }
        XCTAssertEqual(result["isError"] as? Bool, true)
        XCTAssertEqual(text(result), "This call is no longer allowed.")
        XCTAssertFalse(transport.requests.contains { $0.operation == .read })
    }

    /// Reads that leave the message unread, and lists, change nothing on the server and do not ask again.
    func testPlainReadsDoNotAskAgain() async throws {
        respondWithAMessage()
        let checkpoint = Checkpoint()
        for (tool, arguments) in [("read", ["mailbox": mine.uuidString, "uid": 7]),
                                  ("read", ["mailbox": mine.uuidString, "uid": 7, "mark_read": false]),
                                  ("list", ["mailbox": mine.uuidString])] as [(String, [String: Any])] {
            let result = try await direct(tool, arguments) { checkpoint.asked += 1 }
            XCTAssertEqual(result["isError"] as? Bool, false, "\(tool): \(String(describing: result["content"]))")
        }
        XCTAssertEqual(checkpoint.asked, 0)
        XCTAssertEqual(transport.requests.count, 3)
    }

    /// Invalid arguments are tool errors with a usable sentence, and never reach Noodle Mail.
    func testInvalidArgumentsNeverReachTheSocket() async throws {
        let badDate = try await call("search", ["mailbox": mine.uuidString, "since": "yesterday"])
        XCTAssertEqual(badDate["isError"] as? Bool, true)
        XCTAssertEqual(text(badDate), "Use YYYY-MM-DD for dates.")
        let badLimit = try await call("list", ["mailbox": mine.uuidString, "limit": "ten"])
        XCTAssertEqual(text(badLimit), "--limit must be a whole number.")
        XCTAssertTrue(transport.requests.isEmpty)
    }

    /// Results are compact: a one-line text, and the rows once, in structuredContent.
    func testResultsAreStructuredAndCompact() async throws {
        transport.respond = { request in
            var response = MailResponse()
            if request.operation == .list {
                response.messages = [MailMessageRow(uid: 9, date: "2026-10-02T08:00:00Z", from: "ada", subject: "Invoice", seen: false, attachments: 1),
                                     MailMessageRow(uid: 8, date: nil, from: nil, subject: nil, seen: true, attachments: 0)]
            } else {
                response.message = MailMessage(uid: 9, from: "ada", to: ["work@mail.example.org"], cc: [], date: nil, subject: "Invoice", messageId: nil,
                                               text: "Hello", truncated: true, attachments: [MailAttachmentInfo(part: "2", name: "a.pdf", type: "application/pdf", size: 10)])
            }
            return response
        }
        let list = try await call("list", ["mailbox": mine.uuidString])
        XCTAssertEqual(text(list), "2 messages, newest first.")
        let rows = structured(list)["messages"] as? [[String: Any]]
        XCTAssertEqual(rows?.first?["uid"] as? Int, 9)
        XCTAssertNil(rows?.last?["subject"], "absent fields are left out, not null")
        let read = try await call("read", ["mailbox": mine.uuidString, "uid": 9])
        XCTAssertEqual(text(read), "Message (text truncated).")
        XCTAssertEqual((structured(read)["message"] as? [String: Any])?["truncated"] as? Bool, true)
    }

    /// One of anything is counted in the singular in the provider's line. Straight to the provider, because the broker puts its
    /// filtered list in place of the mailboxes line.
    func testACountOfOneIsSingular() async throws {
        transport.respond = { [mine] _ in
            var response = MailResponse()
            response.mailboxes = [RemoteMailbox(id: mine, name: "Work", address: "work@mail.example.org")]
            response.folders = [MailFolderInfo(name: "INBOX", display: "INBOX", role: "inbox")]
            response.messages = [MailMessageRow(uid: 9, date: nil, from: "ada", subject: "Hi", seen: false, attachments: 0)]
            return response
        }
        let mailboxes = try await direct("mailboxes", [:]) {}
        let folders = try await direct("folders", ["mailbox": mine.uuidString]) {}
        let messages = try await direct("list", ["mailbox": mine.uuidString]) {}
        XCTAssertEqual([text(mailboxes), text(folders), text(messages)], ["1 mailbox.", "1 folder.", "1 message, newest first."])
    }

    /// A slash reaches the bot as a slash, in a result and in an error, never as `\/`, which costs tokens and reads badly.
    func testSlashesAreNotEscapedInResultsOrErrors() async throws {
        transport.respond = { _ in
            var response = MailResponse()
            response.messages = [MailMessageRow(uid: 9, date: nil, from: "ada", subject: "a/b", seen: false, attachments: 0)]
            return response
        }
        let listed = String(decoding: try await raw("list", ["mailbox": mine.uuidString]), as: UTF8.self)
        XCTAssertTrue(listed.contains("\"a/b\""), listed)
        XCTAssertFalse(listed.contains("\\/"), listed)
        transport.respond = { _ in MailResponse(error: "No folder a/b.") }
        let failed = String(decoding: try await raw("list", ["mailbox": mine.uuidString]), as: UTF8.self)
        XCTAssertTrue(failed.contains("No folder a/b."), failed)
        XCTAssertFalse(failed.contains("\\/"), failed)
    }

    /// An attachment is written to the new workspace file the bot named.
    func testAttachmentsAreSavedToTheOutputFile() async throws {
        transport.respond = { _ in var response = MailResponse(); response.attachment = MailAttachmentData(data: Data("PDFDATA".utf8)); return response }
        let saved = try await call("attachment", ["mailbox": mine.uuidString, "uid": 9, "part": "2", "output": "invoice.pdf"])
        XCTAssertEqual(saved["isError"] as? Bool, false, String(describing: saved["content"]))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("invoice.pdf")), Data("PDFDATA".utf8))
        XCTAssertEqual(structured(saved)["size"] as? Int, 7)
    }

    /// A failed attachment is a tool error and leaves no file behind.
    func testAFailedAttachmentLeavesNoFile() async throws {
        transport.respond = { _ in MailResponse(error: "This attachment is larger than 20 MB. Open it in a mail app instead.") }
        let failed = try await call("attachment", ["mailbox": mine.uuidString, "uid": 9, "part": "2", "output": "big.pdf"])
        XCTAssertEqual(failed["isError"] as? Bool, true)
        XCTAssertEqual(text(failed), "This attachment is larger than 20 MB. Open it in a mail app instead.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("big.pdf").path))
    }

    /// Noodle Mail's own errors reach the bot word for word, as tool errors.
    func testMailErrorsAreToolErrors() async throws {
        transport.respond = { _ in MailResponse(error: "Open Noodle Mail and enter the password for Work.") }
        let failed = try await call("folders", ["mailbox": mine.uuidString])
        XCTAssertEqual(failed["isError"] as? Bool, true)
        XCTAssertEqual(text(failed), "Open Noodle Mail and enter the password for Work.")
    }

    /// The skill tells bots that mail is untrusted, that this version can't send, how to page, and to quote folder names.
    func testTheSkillCarriesTheMailGuidance() {
        let instructions = provider.manifest.instructions
        XCTAssertTrue(instructions.contains("untrusted"))
        XCTAssertTrue(instructions.contains("cannot send"))
        XCTAssertTrue(instructions.contains("--before-uid"))
        XCTAssertTrue(instructions.contains("never ask for the password"))
        XCTAssertTrue(instructions.contains("Quote folder names"))
        for operation in MailOperation.allCases { XCTAssertFalse(MailToolGuidance.tool(operation).isEmpty, operation.rawValue) }
    }
}
