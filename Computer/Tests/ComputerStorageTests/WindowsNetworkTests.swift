@testable import ComputerEngine
import Virtualization
import XCTest

final class WindowsNetworkTests: XCTestCase {
    /// The Mac's DHCP server hands out addresses by MAC, so a Windows computer keeps its address only when
    /// every start gives its card the MAC stored when it was made.
    func testEveryStartUsesTheStoredMAC() throws {
        let stored = VZMACAddress.randomLocallyAdministered().string
        let devices = WindowsNetwork.devices(enabled: true, macAddress: stored)
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices.first?.macAddress.string, stored)
        XCTAssertTrue(devices.first?.attachment is VZNATNetworkDeviceAttachment)
        XCTAssertTrue(WindowsNetwork.devices(enabled: false, macAddress: stored).isEmpty, "setup runs without a network")
    }
}
