import XCTest
@testable import ComputerBridge

final class ProtocolTests: XCTestCase {
    func testCompatibilityNegotiationDoesNotRequireMatchingAppVersions() throws {
        XCTAssertNoThrow(try ComputerCapabilities.requireCompatible(ComputerCapabilities()))
        var newer = ComputerCapabilities()
        newer.maximumProtocol = 4; newer.features.insert("future-feature")
        XCTAssertNoThrow(try ComputerCapabilities.requireCompatible(newer))
        newer.minimumProtocol = 2
        XCTAssertThrowsError(try ComputerCapabilities.requireCompatible(newer)) {
            XCTAssertTrue($0.localizedDescription.hasPrefix("Update Noodle:"))
        }
        var older = ComputerCapabilities()
        older.features.remove("presentation-v2")
        XCTAssertThrowsError(try ComputerCapabilities.requireCompatible(older)) {
            XCTAssertTrue($0.localizedDescription.hasPrefix("Update Noodle Computer:"))
        }
        XCTAssertThrowsError(try ComputerCapabilities.requireCompatible(nil))
        older.minimumProtocol = 0; older.maximumProtocol = 0
        XCTAssertThrowsError(try ComputerCapabilities.requireCompatible(older))
        older.minimumProtocol = 3; older.maximumProtocol = 1
        XCTAssertThrowsError(try ComputerCapabilities.requireCompatible(older))
        XCTAssertEqual(try JSONDecoder().decode(ComputerCapabilities.self, from: JSONEncoder().encode(newer)), newer)
    }
    func testSimplifiedPresentationAndExplicitSessionSelection() throws {
        let id = UUID()
        XCTAssertNoThrow(try ComputerRequest(.preview, terminalID: id).validate())
        XCTAssertNoThrow(try ComputerRequest(.preview, computerID: id).validate())
        XCTAssertNoThrow(try ComputerRequest(.display, computerID: id).validate())
        XCTAssertThrowsError(try ComputerRequest(.preview).validate())
        XCTAssertThrowsError(try ComputerRequest(.terminalResolve).validate())
        XCTAssertNoThrow(try ComputerRequest(.terminalResolve, terminalID: id).validate())
        var invalid = ComputerRequest(.preview, computerID: id)
        invalid.view = "other"
        XCTAssertThrowsError(try invalid.validate())
        XCTAssertEqual(try ComputerPresentation.terminal(explicit: nil, active: [id]), id)
        XCTAssertEqual(try ComputerPresentation.terminal(explicit: id, active: [id, UUID()]), id)
        XCTAssertThrowsError(try ComputerPresentation.terminal(explicit: nil, active: []))
        XCTAssertThrowsError(try ComputerPresentation.terminal(explicit: nil, active: [id, UUID()]))
    }
    func testWebCardWithoutTerminalAndLegacyTerminalCardDecode() throws {
        let computer = RemoteComputer(id: UUID(), name: "Saved Computer", kind: "Desktop", state: "Running", symbol: "desktopcomputer")
        let card = ComputerCard(computer: computer, agentID: UUID(), terminalPreview: "", view: "web", previewImage: Data([1, 2]))
        let encoded = try JSONEncoder().encode(card)
        XCTAssertEqual(try JSONDecoder().decode(ComputerCard.self, from: encoded), card)
        XCTAssertNil((try JSONSerialization.jsonObject(with: encoded) as! [String: Any])["terminalID"])
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        let terminal = UUID()
        legacy["terminalID"] = terminal.uuidString
        legacy.removeValue(forKey: "view")
        let decoded = try JSONDecoder().decode(ComputerCard.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(decoded.terminalID, terminal)
        XCTAssertNil(decoded.view)
        XCTAssertEqual(decoded.computer, computer)
    }
    func testComputerDownloadsHaveIndependentChannelAndFailClosed() throws {
        XCTAssertEqual(ComputerDistribution.feed.path, "/pdparchitect/noodle/releases/download/computer-latest/appcast.xml")
        XCTAssertEqual(ComputerDistribution.downloadPage.path, "/pdparchitect/noodle/releases/tag/computer-latest")
        XCTAssertEqual(ComputerDistribution.releaseAPI.host, "api.github.com")
        XCTAssertNoThrow(try ComputerDistribution.validateDownloadStatus(200))
        XCTAssertThrowsError(try ComputerDistribution.validateDownloadStatus(404)) { error in
            XCTAssertTrue(error.localizedDescription.contains("does not have a public download yet"))
        }
        for status in [301, 401, 403, 429, 500, 503] {
            XCTAssertThrowsError(try ComputerDistribution.validateDownloadStatus(status))
        }
    }
    func testGuestDisplayOriginCannotEscape() throws {
        let display = ComputerWebConnection(url: URL(string: "http://192.168.64.2:8080/")!, customWeb: true)
        XCTAssertTrue(display.permitsNavigation(to: URL(string: "http://192.168.64.2:8080/login")!))
        for target in ["http://127.0.0.1:8080/", "http://192.168.64.2:9090/", "file:///etc/passwd", "https://example.com/", "http://user:secret@192.168.64.2:8080/"] {
            XCTAssertFalse(display.permitsNavigation(to: URL(string: target)!))
        }
        let defaultPort = ComputerWebConnection(url: URL(string: "https://192.168.64.2/")!)
        XCTAssertTrue(defaultPort.permitsNavigation(to: URL(string: "https://192.168.64.2:443/login")!))
    }
    func testReplayReadersAreIndependentAndBounded() {
        var replay = TerminalReplay(limit: 8)
        replay.append(Data("abcdef".utf8))
        XCTAssertEqual(replay.read(from: 0).data, Data("abcdef".utf8))
        XCTAssertEqual(replay.read(from: 0).data, replay.read(from: 0).data)
        replay.append(Data("ghijkl".utf8))
        let old = replay.read(from: 0)
        XCTAssertEqual(old.data, Data("efghijkl".utf8)); XCTAssertEqual(old.offset, 12)
        XCTAssertEqual(old.truncated, true)
        XCTAssertEqual(replay.read(from: 6).data, Data("ghijkl".utf8))
        XCTAssertEqual(replay.read(from: 12).data, Data())
        XCTAssertEqual(replay.read(from: 99).truncated, true)
    }
    func testRequestsValidateVersionPayloadAndDimensions() throws {
        XCTAssertNoThrow(try ComputerRequest(.list).validate())
        XCTAssertThrowsError(try ComputerRequest(.terminalOpen).validate())
        XCTAssertThrowsError(try ComputerRequest(.terminalRead, computerID: UUID()).validate())
        var request = ComputerRequest(.terminalResize, computerID: UUID(), terminalID: UUID(), columns: 80, rows: 24)
        XCTAssertNoThrow(try request.validate())
        request.rows = 0; XCTAssertThrowsError(try request.validate())
        request.rows = 24; request.columns = 501; XCTAssertThrowsError(try request.validate())
        request.columns = 80; request.version = 99; XCTAssertThrowsError(try request.validate())
        request.version = 1; request.data = Data(count: 65_537); XCTAssertThrowsError(try request.validate())
        request.data = nil; request.offset = -1; XCTAssertThrowsError(try request.validate())
    }
    func testCardRoundTripAndBoundedSnapshot() throws {
        let card = ComputerCard(computer: .init(id: UUID(), name: "Shared", kind: "Shell", state: "Running", symbol: "terminal"),
            agentID: UUID(), terminalID: UUID(), terminalPreview: String(repeating: "x", count: 5000))
        XCTAssertEqual(card.terminalPreview.count, 2000)
        XCTAssertEqual(try JSONDecoder().decode(ComputerCard.self, from: JSONEncoder().encode(card)), card)
    }
    func testSocketPathLimitAndUnsafeExistingFile() throws {
        XCTAssertThrowsError(try ComputerConnection.address(URL(fileURLWithPath: "/" + String(repeating: "x", count: 110))))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("keep".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try ComputerConnectionServer(socket: url, team: "1234567890") { _, _ in .init() })
        XCTAssertEqual(try Data(contentsOf: url), Data("keep".utf8))
    }
}
