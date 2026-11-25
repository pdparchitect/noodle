@testable import ComputerEngine
import ContainerizationExtras
import Foundation
import Virtualization
import XCTest

final class NetworkLinkTests: XCTestCase {
    /// A frame sent at one end arrives whole at the other, and each card is plugged into its own end.
    func testFramesCrossTheLinkWholeInBothDirections() throws {
        let link = try NetworkLink()
        let frame = Data((0..<1514).map { UInt8($0 % 251) })
        for (from, to) in [(link.first, link.second), (link.second, link.first)] {
            let sent = frame.withUnsafeBytes { send(from.fileDescriptor, $0.baseAddress, $0.count, 0) }
            XCTAssertEqual(sent, frame.count)
            var buffer = [UInt8](repeating: 0, count: 4096)
            let received = recv(to.fileDescriptor, &buffer, buffer.count, 0)
            XCTAssertEqual(Data(buffer.prefix(max(received, 0))), frame)
        }
        let card = try LinkInterface(end: link.first, ipv4Address: CIDRv4("10.66.0.2/24"), ipv4Gateway: IPv4Address("10.66.0.1"))
        let attachment = try XCTUnwrap(card.device().attachment as? VZFileHandleNetworkDeviceAttachment)
        XCTAssertEqual(attachment.fileHandle.fileDescriptor, link.first.fileDescriptor)
    }
}
