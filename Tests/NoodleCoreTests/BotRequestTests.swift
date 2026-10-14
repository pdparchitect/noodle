import XCTest
@testable import NoodleCore

final class BotRequestTests: XCTestCase {
    private var root: URL!
    private var repository: WorkspaceRepository!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("noodle-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        repository = WorkspaceRepository(rootURL: root)
        try repository.prepare()
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testAddedRequestIsKeptForBothBots() throws {
        let asker = try repository.createAgent(named: "Assistant").agent
        let helper = try repository.createAgent(named: "Accounts").agent
        let conversation = UUID()
        let added = try repository.addBotRequest(askerID: asker.id, helperID: helper.id, conversationID: conversation,
                                                 text: "Total the invoices in the shared folder")
        XCTAssertEqual(added.askerID, asker.id)
        XCTAssertEqual(added.helperID, helper.id)
        XCTAssertEqual(added.conversationID, conversation)
        XCTAssertEqual(added.text, "Total the invoices in the shared folder")
        XCTAssertEqual(added.status, .waiting)
        XCTAssertEqual(try WorkspaceRepository(rootURL: root).botRequests(), [added])
    }

    func testRequestsAreKeptOutsideEveryWorkspace() throws {
        let asker = try repository.createAgent(named: "Assistant").agent
        let helper = try repository.createAgent(named: "Accounts").agent
        _ = try repository.addBotRequest(askerID: asker.id, helperID: helper.id, conversationID: UUID(), text: "Hello")
        let files = FileManager.default.enumerator(atPath: root.path)?.compactMap { $0 as? String }
            .filter { $0.contains("request") } ?? []
        XCTAssertFalse(files.isEmpty)
        let workspaces = [asker, helper].map { repository.directory(for: $0).standardizedFileURL.path + "/" }
        XCTAssertTrue(files.allSatisfy { file in
            let path = root.appendingPathComponent(file).standardizedFileURL.path
            return !workspaces.contains { path.hasPrefix($0) }
        })
    }

    func testRequestsAddedAtOnceAreAllKept() throws {
        let asker = try repository.createAgent(named: "Assistant").agent
        let helper = try repository.createAgent(named: "Accounts").agent
        let repository = repository!
        DispatchQueue.concurrentPerform(iterations: 20) { index in
            _ = try? repository.addBotRequest(askerID: asker.id, helperID: helper.id, conversationID: UUID(), text: "Request \(index)")
        }
        XCTAssertEqual(Set(try repository.botRequests().map(\.text)), Set((0..<20).map { "Request \($0)" }))
    }
}
