import Foundation
import HubWire
@testable import ServerCore
import XCTest

/// `noodled invite` asks the running server, through a socket only its own account can open, for a link
/// that pairs one device for someone in the file.
@MainActor final class ServerControlTests: XCTestCase {
    private var root: URL!
    private var hub: ServerHub!

    override func setUp() async throws {
        // Socket paths are short everywhere; the temporary folder on a Mac is not.
        root = URL(fileURLWithPath: "/tmp/nd-\(UUID().uuidString.prefix(8))")
        let configuration = try ServerConfiguration(yaml: """
        name: Test Server
        data: \(root.path)
        address: hub.example.com
        users:
          Ada: {}
        """)
        hub = try ServerHub(configuration: configuration, listen: { _, _, _, _ in throw LinkError("not listening") })
        let control = ServerControl(hub: hub, data: root)
        try control.start()
        addTeardownBlock { @MainActor in control.stop() }
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func invite(_ name: String, data: URL? = nil) async throws -> String {
        let data = data ?? root!
        return try await Task.detached { try ServerControl.invite(name, data: data) }.value
    }

    func testAnInvitationPairsADeviceForThatPerson() async throws {
        let invitation = try LinkInvitation(text: try await invite("Ada"))
        XCTAssertEqual(invitation.userName, "Ada")
        XCTAssertEqual(invitation.hubName, "Test Server")
        XCTAssertEqual(invitation.hubKey, hub.link.key)
        XCTAssertTrue(invitation.endpoints.contains(LinkEndpoint(host: "hub.example.com", port: 38_415)), "\(invitation.endpoints)")
    }

    func testOnlyTheServersOwnAccountCanAsk() throws {
        let permissions = try FileManager.default.attributesOfItem(atPath: ServerControl.socket(in: root).path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testSomeoneNotInTheFileIsNotInvited() async {
        do {
            _ = try await invite("Zed")
            XCTFail("Zed was invited")
        } catch {
            XCTAssertEqual(error.localizedDescription, "There is no user called Zed on Test Server.")
        }
    }

    func testAskingWhenTheServerIsNotRunningSaysSo() async {
        let elsewhere = URL(fileURLWithPath: "/tmp/nd-\(UUID().uuidString.prefix(8))")
        do {
            _ = try await invite("Ada", data: elsewhere)
            XCTFail("an invitation came from nowhere")
        } catch {
            XCTAssertEqual(error.localizedDescription, "noodled is not running with its data in \(elsewhere.path).")
        }
    }
}
