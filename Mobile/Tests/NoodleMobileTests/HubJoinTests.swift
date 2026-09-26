import Foundation
import HubLink
import Testing

/// Joins a Hub running in the test over QUIC, as the phone joins a Mac's Hub.
@MainActor @Suite struct HubJoinTests {
    @Test func anInvitationJoinsTheHubAndShowsWhoIJoinedAs() async throws {
        let hubIdentity = LinkIdentity(), join = LinkIdentity()
        // Like a real Hub, only the invitation's key gets in, and the device proves the key it pairs.
        let server = try LinkServer(identity: hubIdentity, port: 0, admits: { $0 == join.publicKey }) { key, data in
            guard case .success(.enroll(let deviceKey, let proof, _)) = LinkProtocol.decode(data),
                  deviceKey.isJoinProof(proof, for: key) else {
                return .response(LinkProtocol.encode(.failure("This invitation was already used.")))
            }
            return .response(LinkProtocol.encode(.status(LinkStatus(hubName: "Studio", userName: "Petko",
                planName: "Everything", harnesses: [], endpoints: []))))
        }
        try await server.start()
        defer { server.stop() }
        let endpoint = LinkEndpoint(host: "127.0.0.1", port: try #require(server.port))
        let invitation = LinkInvitation(hubName: "Studio", hubKey: hubIdentity.publicKey, endpoints: [endpoint],
                                        userName: "Petko", joinKey: join.privateKey.rawRepresentation, expires: Date().addingTimeInterval(600))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }

        let hubs = HubMemberships(directory: directory, deviceName: "iPhone")
        await hubs.join(invitation.url().absoluteString)

        #expect(hubs.joinError == nil)
        let pairing = try #require(hubs.hubs.first)
        #expect(pairing.hub?.name == "Studio")
        #expect(pairing.hub?.userName == "Petko")
        #expect(pairing.status?.planName == "Everything")
        // A relaunch finds the Hub again.
        #expect(HubMemberships(directory: directory, deviceName: "iPhone").hubs.first?.hub?.userName == "Petko")
    }

    @Test func anotherCodeSaysItIsNotAnInvitation() async {
        let hubs = HubMemberships(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString), deviceName: "iPhone")
        await hubs.join("https://example.com")
        #expect(hubs.hubs.isEmpty)
        #expect(hubs.joinError == "This is not a Noodle Hub invitation.")
    }
}
