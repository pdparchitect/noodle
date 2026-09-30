import AppletBridge
import AppletCore
import XCTest

@testable import NoodleApplet

/// What Noodle Hub asks of Applet so a person's device runs a bot's noodlet itself: its files, and
/// its data and secrets, which stay on this Mac.
@MainActor final class DeviceAccessTests: XCTestCase {
    private var root: URL!
    private var runtime: AppletRuntime!
    private var secrets: AppletSecrets!
    private let hub = AppletBuildIdentity.current.hubID

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "DeviceAccess." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { [root] in try? FileManager.default.removeItem(at: root!); defaults.removePersistentDomain(forName: suite) }
        secrets = AppletSecrets(storage: MemorySecrets())
        runtime = AppletRuntime(library: botLibrary(root: root, defaults: defaults, secrets: secrets), defaults: defaults)
    }

    private func noodlet(_ files: [String: Data]) async throws -> (UUID, NoodletPackage) {
        var validate = AppletRequest(.validate)
        validate.path = try botNoodlet(files, named: "Pocket", owner: "bot", root: root, hub: true)
        let response = try await runtime.handle(validate, identity: hub).checked()
        return (try XCTUnwrap(response.noodletID), try NoodletPackage(url: URL(fileURLWithPath: try XCTUnwrap(response.path))))
    }

    private func store(_ id: UUID, _ call: NoodletStoreCall) async throws -> NoodletValue? {
        var request = AppletRequest(.store)
        request.noodletID = id
        request.store = call
        return try await runtime.handle(request, identity: hub).checked().stored
    }

    func testTheHubGetsANoodletsFilesAsOneArchive() async throws {
        var files = try htmlNoodlet("Pocket")
        files["art/logo.svg"] = Data("<svg/>".utf8)
        let (id, package) = try await noodlet(files)
        var request = AppletRequest(.archive)
        request.noodletID = id
        let response = try await runtime.handle(request, identity: hub).checked()
        XCTAssertEqual(response.revision, package.revision)
        XCTAssertEqual(response.manifest?.title, "Pocket")
        var archive = Data()
        while true {
            var piece = AppletRequest(.artifact)
            piece.artifactID = response.artifactID
            piece.offset = archive.count
            let read = try await runtime.handle(piece, identity: hub).checked()
            archive.append(try XCTUnwrap(read.data))
            if read.done == true { break }
        }
        XCTAssertEqual(archive.count, response.byteCount)
        let file = root.appendingPathComponent("received.noodletarchive")
        try archive.write(to: file)
        let out = root.appendingPathComponent("Out.noodlet")
        try NoodletArchive.extract(file, to: out)
        for (name, data) in files { XCTAssertEqual(try Data(contentsOf: out.appendingPathComponent(name)), data, name) }
    }

    /// A device's page keeps the same data and secrets as the noodlet has on this Mac.
    func testTheHubReachesTheNoodletsOwnDataAndSecrets() async throws {
        let (id, package) = try await noodlet(try htmlNoodlet("Pocket"))
        let wrote = try await store(id, NoodletStoreCall(operation: "write", path: "notes/a.txt", text: "hello"))
        XCTAssertEqual(wrote, .bool(true))
        let data = root.appendingPathComponent("Data/\(package.key)/User/notes/a.txt")
        XCTAssertEqual(try String(contentsOf: data, encoding: .utf8), "hello")
        let read = try await store(id, NoodletStoreCall(operation: "read", path: "notes/a.txt"))
        XCTAssertEqual(read, .text("hello"))
        let set = try await store(id, NoodletStoreCall(operation: "secret", action: "set", name: "token", value: "t"))
        XCTAssertEqual(set, .bool(true))
        XCTAssertEqual(secrets.names(), ["\(package.key).user": ["token"]])
        var escape = AppletRequest(.store)
        escape.noodletID = id
        escape.store = NoodletStoreCall(operation: "write", path: "../../x.txt", text: "x")
        let escaped = await runtime.handle(escape, identity: hub)
        XCTAssertNotNil(escaped.error)
    }

    /// Only Noodle and Noodle Hub ask for these, never the command bots run.
    func testTheCommandCannotAskForFilesOrData() async throws {
        let (id, _) = try await noodlet(try htmlNoodlet("Pocket"))
        for operation: AppletOperation in [.archive, .store] {
            var request = AppletRequest(operation)
            request.noodletID = id
            request.store = operation == .store ? NoodletStoreCall(operation: "read", path: "a.txt") : nil
            let response = await runtime.handle(request, identity: AppletBuildIdentity.current.cliID)
            XCTAssertEqual(response.error, "Unknown command. Use --help.", operation.rawValue)
        }
    }

    func testRequestsNameTheNoodletAndTheirCall() throws {
        XCTAssertThrowsError(try AppletRequest(.archive).validate())
        var store = AppletRequest(.store)
        store.noodletID = UUID()
        XCTAssertThrowsError(try store.validate())
        var stray = AppletRequest(.info)
        stray.noodletID = UUID()
        stray.store = NoodletStoreCall(operation: "read", path: "a.txt")
        XCTAssertThrowsError(try stray.validate())
    }
}
