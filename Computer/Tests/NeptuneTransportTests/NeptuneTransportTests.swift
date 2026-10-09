import Foundation
import XCTest
import NeptuneTransport

final class NeptuneTransportTests: XCTestCase {
    func testCommandsAndFencesSurviveTheProcessBoundary() throws {
        let message = NeptuneMessage(-22, [UInt64.max, 7], fences: [NeptuneFence(context: 3, ring: nil, value: 9), NeptuneFence(context: 4, ring: 2, value: UInt64.max)])
        let bytes = Data([0, 255, 10, 0])
        let packet = try NeptuneWire.encode(message, payload: bytes)
        let decoded = try NeptuneWire.decode(packet)
        XCTAssertEqual(decoded.0, message)
        XCTAssertEqual(decoded.1, bytes)
        for malformed in [Data(), Data(packet.dropLast()), packet + Data([0]), Data(repeating: 255, count: 8)] {
            XCTAssertThrowsError(try NeptuneWire.decode(malformed))
        }
    }

    func testDisconnectedRendererIsAnErrorWithoutSIGPIPE() throws {
        let pipe = Pipe()
        try pipe.fileHandleForReading.close()
        XCTAssertThrowsError(try NeptuneWire.write(NeptuneMessage(0), to: pipe.fileHandleForWriting))
    }

    func testEachVMHasIndependentSharedMemoryIncludingFourKiBOffsets() throws {
        let first = try NeptuneMemory(group: "noodle-test", size: 32_768)
        XCTAssertTrue(first.name.hasPrefix("noodle-test/"), "App Sandbox requires the app group followed by a slash")
        let second = try NeptuneMemory(group: "noodle-test", size: 32_768)
        let child = try NeptuneMemory(open: first.name, size: first.size)
        first.pointer.storeBytes(of: UInt32(42), toByteOffset: 4096, as: UInt32.self)
        XCTAssertEqual(child.pointer.load(fromByteOffset: 4096, as: UInt32.self), 42)
        XCTAssertEqual(second.pointer.load(fromByteOffset: 4096, as: UInt32.self), 0)
        child.pointer.storeBytes(of: UInt32(81), toByteOffset: 8192, as: UInt32.self)
        XCTAssertEqual(first.pointer.load(fromByteOffset: 8192, as: UInt32.self), 81)
        first.unlink()
        XCTAssertThrowsError(try NeptuneMemory(open: first.name, size: first.size))
        XCTAssertEqual(child.pointer.load(fromByteOffset: 4096, as: UInt32.self), 42, "Unlinking removes the name, not either live mapping")
        XCTAssertThrowsError(try NeptuneMemory(open: second.name, size: 16_384), "A child cannot map an arena with the wrong length")
    }
}
