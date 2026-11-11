import Foundation
import SurfaceWire
import XCTest

final class SurfaceWireTests: XCTestCase {
    private func pair() throws -> (SurfaceSocket, SurfaceSocket) {
        var fds: [Int32] = [0, 0]
        #if canImport(Darwin)
        let stream = SOCK_STREAM
        #else
        let stream = Int32(SOCK_STREAM.rawValue)
        #endif
        XCTAssertEqual(socketpair(AF_UNIX, stream, 0, &fds), 0)
        let ends = (SurfaceSocket(fd: fds[0]), SurfaceSocket(fd: fds[1]))
        addTeardownBlock { ends.0.close(); ends.1.close() }
        return ends
    }

    func testInputRoundTripsThroughJSON() throws {
        let inputs: [SurfaceInput] = [.pointer(.down, x: 10, y: 20, clickCount: 2), .scroll(x: 5, y: 6, dx: 0, dy: -40),
                                      .key(.enter), .text("héllo")]
        for input in inputs {
            XCTAssertEqual(try JSONDecoder().decode(SurfaceInput.self, from: JSONEncoder().encode(input)), input)
        }
        for control in inputs.map(SurfaceControl.input) + [.view(width: 1200, height: 800), .keyFrame, .rate(bitsPerSecond: 1_000_000)] {
            XCTAssertEqual(SurfaceControl(control.encoded), control)
        }
    }

    /// Only a status reads as one, whatever else crosses the same channel.
    func testOnlyAStatusReadsAsOne() {
        for notice in [SurfaceNotice.starting, .notResponding, nil] {
            XCTAssertEqual(SurfaceStatus(SurfaceStatus(notice: notice).encoded), SurfaceStatus(notice: notice))
        }
        XCTAssertNil(SurfaceStatus(Data("{}".utf8)))
        XCTAssertNil(SurfaceStatus(Data(#"{"surfaceOpened":{"sessionID":"00000000-0000-0000-0000-000000000000"}}"#.utf8)))
        XCTAssertNil(SurfaceStatus(SurfaceControl.keyFrame.encoded))
    }

    /// Frames cross in order both ways, and closing one end ends the other.
    func testASocketCarriesFramesBothWays() async throws {
        let (companion, hub) = try pair()
        companion.send(Data([1, 2, 3]))
        companion.send(Data(repeating: 7, count: 200_000))
        hub.send(Data("{}".utf8))
        var down: [Data] = []
        for await frame in hub.frames { down.append(frame); if down.count == 2 { break } }
        XCTAssertEqual(down, [Data([1, 2, 3]), Data(repeating: 7, count: 200_000)])
        for await frame in companion.frames { XCTAssertEqual(frame, Data("{}".utf8)); break }
        companion.close()
        var more = 0
        for await _ in hub.frames { more += 1 }
        XCTAssertEqual(more, 0)
    }

    /// Video sent to a viewer that has gone ends the view, not the process sending it.
    func testSendingToAViewerThatLeftEndsOnlyTheView() async throws {
        var fds: [Int32] = [0, 0]
        #if canImport(Darwin)
        let stream = SOCK_STREAM
        #else
        let stream = Int32(SOCK_STREAM.rawValue)
        #endif
        XCTAssertEqual(socketpair(AF_UNIX, stream, 0, &fds), 0)
        _ = close(fds[1])
        let companion = SurfaceSocket(fd: fds[0])
        defer { companion.close() }
        for _ in 0..<100 where !companion.isClosed {
            companion.send(Data(repeating: 1, count: 64_000))
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(companion.isClosed)
    }
}
