import ComputerBridge
import XCTest
@testable import NoodleCore

final class ComputerAgentFilesTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testConcurrentReadersOnlyObserveCompleteJSONMessages() async throws {
        let root = try directory(), destination = root.appendingPathComponent("message.response")
        func message(_ index: Int) -> ComputerResponse {
            var response = ComputerResponse(data: Data(repeating: UInt8(truncatingIfNeeded: index), count: 65_536))
            response.byteCount = 65_536; response.path = String(index)
            return response
        }
        try ComputerAgentFiles.write(message(0), to: destination)
        let writer = Task.detached {
            for index in 1...128 { try ComputerAgentFiles.write(message(index), to: destination) }
        }
        var failure: Error?
        for _ in 0..<2000 {
            do {
                let bytes = try MCPBridgeFiles.read(destination, limit: 150_000)
                let response = try JSONDecoder().decode(ComputerResponse.self, from: bytes)
                XCTAssertEqual(response.byteCount, Int64(response.data?.count ?? -1))
                let index = try XCTUnwrap(response.path.flatMap(Int.init))
                XCTAssertEqual(response.data, message(index).data)
            } catch { failure = error; break }
        }
        try await writer.value
        if let failure { XCTFail("Reader observed an incomplete bridge message: \(failure)") }
        let final = try JSONDecoder().decode(ComputerResponse.self, from: Data(contentsOf: destination))
        XCTAssertEqual(final.path, "128")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["message.response"])
    }

    func testPublicationReplacesSymlinkAndRemovesTemporaryFileOnFailure() throws {
        let root = try directory(), target = root.appendingPathComponent("keep")
        let destination = root.appendingPathComponent("message.response")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: target)
        try ComputerAgentFiles.write(ComputerResponse(error: "fixture"), to: destination)
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
        XCTAssertEqual(try JSONDecoder().decode(ComputerResponse.self, from: Data(contentsOf: destination)).error, "fixture")
        let invalid = root.appendingPathComponent("directory.response")
        try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: false)
        XCTAssertThrowsError(try ComputerAgentFiles.write(ComputerResponse(), to: invalid))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["keep", "message.response", "directory.response"])
    }
}
