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

/// Network tools Kali installs with file capabilities, such as nmap, start only when the computer may grant them: Linux
/// refuses to run a program that asks for more, even as root. Each computer is its own virtual machine.
final class GuestCapabilityTests: XCTestCase {
    func testProgramsInTheComputerMayManageItsNetwork() {
        let capabilities = ContainerComputer.workspaceCapabilities
        for set in [capabilities.bounding, capabilities.effective, capabilities.permitted] {
            XCTAssertTrue(set.contains(.netAdmin))
            XCTAssertTrue(set.contains(.netRaw))
        }
        XCTAssertFalse(capabilities.bounding.contains(.sysAdmin), "nothing beyond the network is added")
    }
}
