import Network
import XCTest
@testable import NoodletRuntime

/// The public web is open to every noodlet. This device and the network it is on are open only
/// to one that declares local-network and that the person allowed.
@MainActor final class WebNetworkLocalTests: XCTestCase {
    /// Answers every request with "ok" on this Mac's loopback address, to anyone.
    private func server() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                let reply = "HTTP/1.1 200 OK\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"
                connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        let ready = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .main)
        addTeardownBlock { listener.cancel() }
        await fulfillment(of: [ready], timeout: 5)
        return try XCTUnwrap(listener.port?.rawValue)
    }

    func testLocalNetworkIsKnownAsAPermission() throws {
        var manifest = NoodletManifest(title: "Remote")
        manifest.permissions = ["local-network"]
        XCTAssertNoThrow(try manifest.validate())
        XCTAssertFalse(manifest.streams, "the Hub never streams a noodlet that asks for the network it is on")
    }

    func testTheDeviceAndItsNetworkStayClosedUnlessAllowed() async {
        let network = WebNetwork(localNetwork: false)
        for url in ["http://127.0.0.1:9/", "http://127.1:9/", "http://2130706433:9/", "http://localhost:9/",
                    "http://[::1]:9/", "http://[::ffff:127.0.0.1]:9/", "http://0.0.0.0:9/"] {
            do {
                _ = try await network.fetch(["id": "local", "url": url])
                XCTFail("\(url) was fetched")
            } catch {
                XCTAssertEqual(error.localizedDescription, WebNetwork.localRefusal, url)
            }
        }
    }

    func testAllowedTheNetworkItIsOnIsOpen() async throws {
        let port = try await server()
        let answer = try await WebNetwork(localNetwork: true).fetch(["id": "local", "url": "http://127.0.0.1:\(port)/"])
        XCTAssertEqual(answer["body"] as? String, Data("ok".utf8).base64EncodedString())
    }

    /// Nothing to declare and nothing to allow for the public web; a name that leads nowhere
    /// fails as it would in a browser.
    func testThePublicWebIsOpenWithoutAsking() async {
        do {
            _ = try await WebNetwork(localNetwork: false).fetch(["id": "web", "url": "https://noodlet.invalid/"])
            XCTFail("a name that leads nowhere answered")
        } catch {
            XCTAssertNotEqual(error.localizedDescription, WebNetwork.localRefusal)
            XCTAssertFalse(error.localizedDescription.contains("noodlet.json"), error.localizedDescription)
        }
    }

    func testAddressesAreSortedIntoPublicAndLocal() {
        for local in ["127.0.0.1", "10.1.2.3", "172.16.0.1", "192.168.1.1", "169.254.1.1", "100.64.0.1", "0.0.0.0",
                      "224.0.0.1", "255.255.255.255", "::1", "::", "fe80::1", "fd00::1", "ff02::1", "::ffff:192.168.1.1",
                      "64:ff9b::a00:1"] {
            XCTAssertFalse(WebNetwork.isPublic(address: local), local)
        }
        for open in ["93.184.215.14", "8.8.8.8", "2606:2800:21f:cb07:6820:80da:af6b:8b2c", "::ffff:8.8.8.8", "64:ff9b::808:808"] {
            XCTAssertTrue(WebNetwork.isPublic(address: open), open)
        }
    }

    func testARedirectToTheLocalNetworkIsNotFollowedUnlessAllowed() {
        func follows(localNetwork: Bool) -> Bool {
            let policy = RedirectPolicy(mode: "follow", localNetwork: localNetwork)
            let from = HTTPURLResponse(url: URL(string: "https://example.com/")!, statusCode: 302, httpVersion: nil, headerFields: nil)!
            var followed = false
            policy.urlSession(.shared, task: URLSession.shared.dataTask(with: URL(string: "https://example.com/")!),
                              willPerformHTTPRedirection: from, newRequest: URLRequest(url: URL(string: "http://127.0.0.1:9/")!)) {
                followed = $0 != nil
            }
            return followed
        }
        XCTAssertFalse(follows(localNetwork: false))
        XCTAssertTrue(follows(localNetwork: true))
    }

    /// What the page loads itself, outside fetch, keeps to the same rule.
    func testThePagesOwnRequestsKeepToTheSameRule() async throws {
        let port = try await server()
        for allowed in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".noodlet")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data("<title>Page</title>".utf8).write(to: root.appendingPathComponent("index.html"))
            addTeardownBlock { try? FileManager.default.removeItem(at: root) }
            var manifest = NoodletManifest(title: "Page")
            if allowed { manifest.permissions = ["local-network"] }
            let page = NoodletPage(root: root, manifest: manifest, store: MemoryStore(), dataStore: .nonPersistent(),
                                   frame: CGRect(x: 0, y: 0, width: 320, height: 240), localNetwork: allowed) { _, _ in }
            defer { page.stop() }
            try await page.load()
            let features = try await page.evaluate("return noodle.features")
            XCTAssertEqual(features.contains("\"local-network\""), allowed, features)
            let answer = try await page.evaluate("""
                return await new Promise(done => {
                  const request = new XMLHttpRequest();
                  request.onload = () => done(request.responseText);
                  request.onerror = () => done('blocked');
                  request.open('GET', 'http://127.0.0.1:\(port)/');
                  request.send();
                })
                """)
            XCTAssertEqual(answer, allowed ? "\"ok\"" : "\"blocked\"", "allowed: \(allowed)")
        }
    }
}
