import Containerization
import XCTest
@testable import ComputerEngine

/// A computer finds its own name, as sudo looks for it on every run and warns when it is missing.
final class GuestHostnameTests: XCTestCase {
    func testTheHostsFileNamesTheComputer() {
        let lines = ContainerComputer.hosts(for: "rook-computer").hostsFile.split(separator: "\n").map(String.init)
        XCTAssertTrue(lines.contains("127.0.0.1 localhost"))
        XCTAssertTrue(lines.contains("127.0.1.1 rook-computer"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("::1 localhost") })
    }
}
