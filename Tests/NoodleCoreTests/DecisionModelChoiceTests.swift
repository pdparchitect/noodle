import NoodleCore
import XCTest

/// The chosen decision model round-trips through disk and resolves to a live
/// client through the account's provider base and key.
final class DecisionModelChoiceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testChoiceRoundTripsAndClears() throws {
        let store = DecisionModelChoiceStore(repository: root)
        XCTAssertNil(store.load())
        let choice = DecisionModelChoice(accountID: UUID(), modelID: "pplx-decider-v1.1-27b-20261006", displayName: "Pplx Decider")
        try store.save(choice)
        XCTAssertEqual(store.load(), choice)
        try store.save(nil)
        XCTAssertNil(store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file.path))
    }

    final class KeychainStub: RemoteModelSecrets {
        private var keys: [UUID: String] = [:]
        func read(_ account: UUID) throws -> String? { keys[account] }
        func write(_ key: String, account: UUID) throws { keys[account] = key }
        func delete(_ account: UUID) throws { keys[account] = nil }
    }

    final class CatalogTransport: RemoteTransport, @unchecked Sendable {
        func send(_ request: URLRequest) async throws -> RemoteHTTPResponse {
            let body = #"{"data":[{"id":"pplx/pplx-decider-v1.1-27b","canonical_slug":"pplx-decider-v1.1-27b-20261006","name":"Pplx Decider","architecture":{"input_modalities":["text"],"output_modalities":["decisions"]}}]}"#
            let lines = AsyncThrowingStream<String, Error> { $0.yield(body); $0.finish() }
            return RemoteHTTPResponse(status: 200, headers: [:], lines: lines)
        }
    }

    func testResolverRoutesToThePinnedModelClient() async throws {
        let secrets = KeychainStub()
        let accounts = RemoteModelAccountStore(repository: root, secrets: secrets)
        let account = try accounts.add(providerID: "openrouter", name: "Probe", apiKey: "key")
        let choice = DecisionModelChoice(accountID: account.id, modelID: "pplx-decider-v1.1-27b-20261006", displayName: "Pplx Decider")
        let serving = try await DecisionModelResolver.serving(choice, accounts: accounts, secrets: secrets, transport: CatalogTransport())
        guard let router = serving as? DecisionModelRouter,
            let client = router.preferred as? RemoteDecisionsClient else {
            return XCTFail("The resolver must route through the on-device fallback to the pinned client.")
        }
        XCTAssertEqual(client.model.requestID, "pplx-decider-v1.1-27b-20261006")
    }

    func testResolverThrowsWhenModelLeftCatalog() async throws {
        let secrets = KeychainStub()
        let accounts = RemoteModelAccountStore(repository: root, secrets: secrets)
        let account = try accounts.add(providerID: "openrouter", name: "Probe", apiKey: "key")
        let choice = DecisionModelChoice(accountID: account.id, modelID: "gone-model", displayName: "Gone")
        do {
            _ = try await DecisionModelResolver.serving(choice, accounts: accounts, secrets: secrets, transport: CatalogTransport())
            XCTFail("A model missing from the catalog must not resolve.")
        } catch {}
    }

    func testResolverThrowsForRemovedAccount() async throws {
        let secrets = KeychainStub()
        let accounts = RemoteModelAccountStore(repository: root, secrets: secrets)
        let choice = DecisionModelChoice(accountID: UUID(), modelID: "any", displayName: "Any")
        do {
            _ = try await DecisionModelResolver.serving(choice, accounts: accounts, secrets: secrets, transport: CatalogTransport())
            XCTFail("A choice pointing at a removed account must not resolve.")
        } catch {}
    }
}
