import ComputerBridge
import Foundation
import Darwin

/// Signed sandbox transport proof; never installed or used by either product.
@main enum Probe {
    static func main() async {
        do {
            let url = try ComputerConnection.socketURL(), team = try ComputerConnection.signingTeam()
            if CommandLine.arguments.contains("server") {
                let server = try ComputerConnectionServer(socket: url, team: team, clientIDs: ["com.pdparchitect.noodle.bridgeproof.client"]) { request, peer in
                    .init(computers: [.init(id: UUID(), name: peer, kind: "Proof", state: "Running", symbol: "terminal")])
                }
                print("READY"); fflush(stdout)
                try await Task.sleep(for: .seconds(55))
                withExtendedLifetime(server) {}
            } else {
                for _ in 0..<20 {
                    let response = try await ComputerConnection.call(.init(.list), socket: url, team: team,
                        providerID: "com.pdparchitect.noodle.bridgeproof.server")
                    guard response.computers?.first?.name == "com.pdparchitect.noodle.bridgeproof.client" else {
                        throw ComputerBridgeError("Unexpected authenticated response.")
                    }
                }
                print("PASS: 20 sandboxed, mutually authenticated round trips")
            }
        } catch {
            print("FAIL: \(error.localizedDescription)"); fflush(stdout); exit(1)
        }
    }
}
