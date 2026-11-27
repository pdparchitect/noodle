import Foundation
import HubWire
@testable import ServerCore
import XCTest
#if os(Windows)
import WinSDK
#endif

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
        #if os(Windows)
        // A named pipe there, which only this account, SYSTEM and Administrators may open.
        let name = ServerControl.pipeName(ServerControl.socket(in: root).path)
        let pipe = try XCTUnwrap(name.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, DWORD(READ_CONTROL), 0, nil, DWORD(OPEN_EXISTING), 0, nil)
        })
        XCTAssertNotEqual(pipe, INVALID_HANDLE_VALUE)
        defer { CloseHandle(pipe) }
        var acl: PACL?, descriptor: PSECURITY_DESCRIPTOR?
        XCTAssertEqual(GetSecurityInfo(pipe, SE_KERNEL_OBJECT, SECURITY_INFORMATION(DACL_SECURITY_INFORMATION), nil, nil, &acl, nil, &descriptor),
                       DWORD(ERROR_SUCCESS))
        defer { LocalFree(descriptor) }
        var token: HANDLE?
        XCTAssertTrue(OpenProcessToken(GetCurrentProcess(), DWORD(TOKEN_QUERY), &token))
        defer { CloseHandle(token) }
        var size: DWORD = 0
        GetTokenInformation(token, TokenUser, nil, 0, &size)
        let user = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { user.deallocate() }
        XCTAssertTrue(GetTokenInformation(token, TokenUser, user, size, &size))
        let own = user.assumingMemoryBound(to: TOKEN_USER.self).pointee.User.Sid
        let list = try XCTUnwrap(acl)
        XCTAssertGreaterThan(list.pointee.AceCount, 0)
        for index in 0..<DWORD(list.pointee.AceCount) {
            var entry: LPVOID?
            XCTAssertTrue(GetAce(list, index, &entry))
            let ace = try XCTUnwrap(entry).assumingMemoryBound(to: ACCESS_ALLOWED_ACE.self)
            let sid = PSID(withUnsafeMutablePointer(to: &ace.pointee.SidStart) { UnsafeMutableRawPointer($0) })
            XCTAssertTrue(EqualSid(sid, own) || IsWellKnownSid(sid, WinLocalSystemSid) || IsWellKnownSid(sid, WinBuiltinAdministratorsSid),
                          "someone else may open the control pipe")
        }
        #else
        let permissions = try FileManager.default.attributesOfItem(atPath: ServerControl.socket(in: root).path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        #endif
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
