import ComputerCore
import XCTest
@testable import NoodleComputer

final class WindowsAgentTests: XCTestCase {
    /// Uploads, terminal input and requests are sent from different threads; a frame larger than the socket's
    /// buffer is written in pieces, and the pieces of two frames must not interleave on the way to Windows.
    func testFramesSentFromManyThreadsArriveWhole() throws {
        let agent = WindowsAgent()
        let senders = 8, each = 6, size = 150_000
        let outcome = Outcome()
        let reader = Thread {
            var decoder = WindowsAgentFrame.Decoder()
            var intact = true
            var bytes = 0
            // Keep draining after a broken frame, so the senders never block on a full socket.
            while bytes < senders * each * (size + 9) {
                let data = agent.guest.availableData
                guard !data.isEmpty else { break }
                bytes += data.count
                guard intact else { continue }
                do {
                    for frame in try decoder.append(data) {
                        if frame.payload != Data(repeating: UInt8(frame.channel), count: size) { intact = false }
                        else { outcome.frames += 1 }
                    }
                } catch { intact = false }
            }
            outcome.finish(intact)
        }
        reader.start()
        DispatchQueue.global().async {
            DispatchQueue.concurrentPerform(iterations: senders) { sender in
                for _ in 0..<each { agent.send(14, channel: UInt32(sender + 1), payload: Data(repeating: UInt8(sender + 1), count: size)) }
            }
        }
        XCTAssertEqual(outcome.wait(seconds: 120), true, "frames from different threads interleaved")
        XCTAssertEqual(outcome.frames, senders * each)
    }

    private final class Outcome: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        private var intact: Bool?
        var frames = 0
        func finish(_ intact: Bool) { self.intact = intact; done.signal() }
        func wait(seconds: Double) -> Bool? { done.wait(timeout: .now() + seconds) == .success ? intact : nil }
    }
}
