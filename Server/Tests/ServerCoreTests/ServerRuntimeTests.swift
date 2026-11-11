import Foundation
import HubWire
import NoodleCore
@testable import ServerCore
import XCTest

/// Bots on the server run the harnesses its file names, from where the file says, and no other the
/// machine happens to have.
@MainActor final class ServerRuntimeTests: XCTestCase {
    func testBotsRunOnlyTheHarnessesInTheFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("noodled-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let configuration = try ServerConfiguration(yaml: """
        data: \(root.path)
        harnesses:
          claude-code: /bin/sh
        plans:
          Family:
            harnesses: [claude-code]
        users:
          Ada:
            plan: Family
        """)
        let hub = try ServerHub(configuration: configuration, listen: { _, _, _, _ in throw LinkError("not listening") })
        let available = hub.runtime.installations.filter(\.isAvailable)
        XCTAssertEqual(available.map(\.provider), [.claudeCode])
        XCTAssertEqual(available.first?.executablePath, "/bin/sh")
    }
}
