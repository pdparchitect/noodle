import Darwin
import Foundation
@testable import HubLink
import XCTest

final class LinkSurfaceTests: XCTestCase {
    /// What the device has shown reaches the companion too, which builds recovery frames on it.
    func testTheCompanionHearsWhatTheDeviceHasShown() async throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let companion = SurfaceSocket(fd: fds[0]), hubEnd = SurfaceSocket(fd: fds[1])
        let hub = LinkIdentity()
        let server = try LinkServer(identity: hub, port: 0, admits: { _ in true }, handler: { _, _ in
            .stream { LinkSurface.relay(hubEnd, to: $0) }
        })
        try await server.start()
        defer { companion.close(); server.stop() }
        let channel = try await LinkClient.channel(Data("{}".utf8), identity: LinkIdentity(), hubKey: hub.publicKey,
                                                   endpoints: [LinkEndpoint(host: "::1", port: try XCTUnwrap(server.port))])
        defer { channel.cancel() }
        channel.send(SurfaceControl.shown(sequence: 5).encoded)
        channel.send(SurfaceControl.input(.key(.enter)).encoded)
        var heard: [SurfaceControl] = []
        for await frame in companion.frames {
            // The Hub's own say on the rate is not the device's.
            if let control = SurfaceControl(frame), !{ if case .rate = control { true } else { false } }() { heard.append(control) }
            if heard.contains(.input(.key(.enter))) { break }
        }
        XCTAssertEqual(heard, [.shown(sequence: 5), .input(.key(.enter))])
    }

    /// The device hears why the surface shows nothing new, through the Hub, whatever the video is doing.
    func testTheDeviceHearsWhyTheSurfaceShowsNothingNew() async throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let companion = SurfaceSocket(fd: fds[0]), hubEnd = SurfaceSocket(fd: fds[1])
        let hub = LinkIdentity()
        let server = try LinkServer(identity: hub, port: 0, admits: { _ in true }, handler: { _, _ in
            .stream { LinkSurface.relay(hubEnd, to: $0) }
        })
        try await server.start()
        defer { companion.close(); server.stop() }
        let channel = try await LinkClient.channel(Data("{}".utf8), identity: LinkIdentity(), hubKey: hub.publicKey,
                                                   endpoints: [LinkEndpoint(host: "::1", port: try XCTUnwrap(server.port))])
        defer { channel.cancel() }
        companion.send(SurfaceStatus(notice: .notResponding).encoded)
        companion.send(SurfaceStatus(notice: nil).encoded)
        let deadline = Task { try await Task.sleep(for: .seconds(10)); channel.cancel() }
        defer { deadline.cancel() }
        var heard: [LinkSurface.Message] = []
        for try await frame in channel.frames {
            if let message = LinkSurface.message(frame) { heard.append(message) }
            if heard.count == 2 { break }
        }
        XCTAssertEqual(heard, [.notice(.notResponding), .notice(nil)])
    }

    /// How late each frame reached a device that says what it has shown, over `seconds` of a live
    /// view through a link of `bitsPerSecond`, from a companion that can send up to `ceiling`.
    private func watch(for seconds: Double, bitsPerSecond: Double, ceiling: Double) async throws
        -> (late: [(at: Double, seconds: Double)], rate: Double) {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        let companion = SurfaceSocket(fd: fds[0]), hubEnd = SurfaceSocket(fd: fds[1])
        let hub = LinkIdentity()
        let server = try LinkServer(identity: hub, port: 0, admits: { _ in true }, handler: { _, _ in
            .stream { LinkSurface.relay(hubEnd, to: $0) }
        })
        try await server.start()
        let link = try SlowLink(to: try XCTUnwrap(server.port), bitsPerSecond: bitsPerSecond, queueSeconds: 0.5)
        let video = FakeCompanion(companion, bitsPerSecond: ceiling, fps: 30)
        defer { video.stop(); companion.close(); link.stop(); server.stop() }

        let channel = try await LinkClient.channel(Data("{}".utf8), identity: LinkIdentity(), hubKey: hub.publicKey,
                                                   endpoints: [LinkEndpoint(host: "::1", port: link.port)])
        defer { channel.cancel() }
        // As a viewer does once its channel opens.
        channel.send(SurfaceControl.shown(sequence: 0).encoded)
        // Video that stops altogether must not hold the test up.
        let deadline = Task { try await Task.sleep(for: .seconds(seconds + 2)); channel.cancel() }
        defer { deadline.cancel() }
        let start = ContinuousClock.now
        var late: [(at: Double, seconds: Double)] = []
        for try await frame in channel.frames {
            let now = ContinuousClock.now
            for packet in SurfacePacket.decode(frame) ?? [] {
                if let sent = video.sent(packet.sequence) { late.append(((now - start) / .seconds(1), (now - sent) / .seconds(1))) }
                channel.send(SurfaceControl.shown(sequence: packet.sequence).encoded)
            }
            if now - start > .seconds(seconds) { break }
        }
        return (late, video.currentRate)
    }

    /// These pace a real link in real time, so a busy Mac or a virtual machine's coarse timers
    /// change what they measure. SurfaceFlowTests check the same behaviour without a clock; run
    /// these with NOODLE_LINK_TESTS=1 to see it over QUIC.
    private func skipUnlessPacingIsReal() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NOODLE_LINK_TESTS"] != nil, "set NOODLE_LINK_TESTS=1 to run over a paced link")
        var virtual: Int32 = 0, size = MemoryLayout<Int32>.size
        sysctlbyname("kern.hv_vmm_present", &virtual, &size, nil, 0)
        try XCTSkipIf(virtual == 1, "this Mac is a virtual machine")
    }

    /// On a link slower than the video, what the device sees stays close to live: the Hub learns
    /// from what the device says it has shown that frames take longer to arrive, and has the
    /// companion send less, instead of letting them pile up in the network and arrive seconds late.
    func testLiveVideoStaysLiveOnASlowLink() async throws {
        try skipUnlessPacingIsReal()
        let (late, _) = try await watch(for: 10, bitsPerSecond: 2_000_000, ceiling: 6_000_000)
        // The first seconds find the link's pace; after that video should stay live.
        let settled = late.filter { $0.at > 5 }.map(\.seconds).sorted()
        XCTAssertFalse(settled.isEmpty, "no video came through")
        let median = settled.isEmpty ? 0 : settled[settled.count / 2], worst = settled.last ?? 0
        XCTAssertLessThan(median, 0.2, "frames arrived \(String(format: "%.2f", median)) s after they were sent")
        XCTAssertLessThan(worst, 0.5, "frames arrived up to \(String(format: "%.2f", worst)) s after they were sent")
    }

    /// A view on a slow link is live within its first second, instead of spending seconds
    /// finding the link's pace behind video it cannot carry.
    func testAViewStartsLiveOnASlowLink() async throws {
        try skipUnlessPacingIsReal()
        let (late, _) = try await watch(for: 3, bitsPerSecond: 2_000_000, ceiling: 6_000_000)
        let start = late.filter { $0.at > 1 }.map(\.seconds)
        XCTAssertGreaterThan(start.count, 30, "only \(start.count) frames came in two seconds")
        let worst = start.max() ?? 0
        XCTAssertLessThan(worst, 0.5, "after the first second, frames still arrived up to \(String(format: "%.2f", worst)) s late")
    }

    /// Starting carefully costs a fast link nothing: video reaches the most the companion sends
    /// within two seconds.
    func testAViewOnAFastLinkReachesFullRateQuickly() async throws {
        try skipUnlessPacingIsReal()
        let (late, rate) = try await watch(for: 2, bitsPerSecond: 60_000_000, ceiling: 8_000_000)
        XCTAssertGreaterThan(late.count, 45)
        XCTAssertGreaterThanOrEqual(rate, 7_000_000, "after two seconds the companion was asked for only \(Int(rate)) bits a second")
    }
}

/// A companion's side of a live view: frames at a steady pace, as large as the rate the Hub
/// last asked for allows, and a key frame, four times larger, when asked.
private final class FakeCompanion: @unchecked Sendable {
    private let lock = NSLock()
    private var rate: Double
    private var wantsKeyFrame = true
    private var times: [UInt64: ContinuousClock.Instant] = [:]
    private var running = true

    init(_ socket: SurfaceSocket, bitsPerSecond: Double, fps: Int) {
        rate = bitsPerSecond
        let ceiling = bitsPerSecond
        Task { [self] in
            for await frame in socket.frames {
                switch SurfaceControl(frame) {
                case .rate(let asked)?: lock.withLock { rate = min(ceiling, asked) }
                case .keyFrame?: lock.withLock { wantsKeyFrame = true }
                default: break
                }
            }
        }
        Thread.detachNewThread { [self] in
            var sequence: UInt64 = 0
            let interval = 1 / Double(fps)
            let begin = Date()
            while lock.withLock({ running }) {
                sequence += 1
                let (key, bytes) = lock.withLock { () -> (Bool, Int) in
                    defer { wantsKeyFrame = false }
                    return (wantsKeyFrame, Int(rate / 8 / Double(fps)) * (wantsKeyFrame ? 4 : 1))
                }
                let packet = SurfacePacket(sequence: sequence, keyFrame: key, width: 800, height: 500,
                                           parameterSets: key ? [Data([1]), Data([2])] : [], sample: Data(count: max(200, bytes)))
                lock.withLock { times[sequence] = .now }
                socket.send(SurfacePacket.encode([packet]))
                Thread.sleep(until: begin.addingTimeInterval(Double(sequence) * interval))
            }
        }
    }

    var currentRate: Double { lock.withLock { rate } }

    func sent(_ sequence: UInt64) -> ContinuousClock.Instant? { lock.withLock { times[sequence] } }

    func stop() { lock.withLock { running = false } }
}

/// A slow network between a device and the Hub, as a UDP relay: what the Hub sends waits in a
/// queue and leaves at `bitsPerSecond`, and is dropped when the queue holds more than
/// `queueSeconds` of it, as a router does. What the device sends passes at once.
private final class SlowLink: @unchecked Sendable {
    let port: UInt16
    private let near: Int32, far: Int32
    private let lock = NSLock()
    private var running = true

    init(to hubPort: UInt16, bitsPerSecond: Double, queueSeconds: Double) throws {
        let near = socket(AF_INET6, SOCK_DGRAM, 0), far = socket(AF_INET6, SOCK_DGRAM, 0)
        self.near = near
        self.far = far
        var address = sockaddr_in6()
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_addr = in6addr_loopback
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        guard withUnsafePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(near, $0, length) } }) == 0,
              withUnsafeMutablePointer(to: &address, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(near, $0, &length) } }) == 0
        else { throw POSIXError(.EADDRNOTAVAIL) }
        port = UInt16(bigEndian: address.sin6_port)
        var hub = sockaddr_in6()
        hub.sin6_family = sa_family_t(AF_INET6)
        hub.sin6_addr = in6addr_loopback
        hub.sin6_port = hubPort.bigEndian
        guard withUnsafePointer(to: &hub, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(far, $0, length) } }) == 0
        else { throw POSIXError(.ECONNREFUSED) }
        let limit = Int(bitsPerSecond / 8 * queueSeconds)
        Thread.detachNewThread { [self] in
            var device = sockaddr_in6(), deviceLength = socklen_t(0)
            var queue: [(packet: [UInt8], due: Double)] = [], head = 0, queued = 0, lastDue = 0.0
            var buffer = [UInt8](repeating: 0, count: 65_536)
            func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
            while lock.withLock({ running }) {
                while head < queue.count, queue[head].due <= now() {
                    let packet = queue[head].packet
                    _ = withUnsafePointer(to: &device) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(near, packet, packet.count, 0, $0, deviceLength) }
                    }
                    queued -= packet.count
                    head += 1
                }
                if head > 1024 { queue.removeFirst(head); head = 0 }
                let wait = head < queue.count ? max(1, Int32(((queue[head].due - now()) * 1000).rounded(.up))) : 20
                var polled = [pollfd(fd: near, events: Int16(POLLIN), revents: 0), pollfd(fd: far, events: Int16(POLLIN), revents: 0)]
                guard poll(&polled, 2, wait) >= 0 else { continue }
                if polled[0].revents & Int16(POLLIN) != 0 {
                    deviceLength = socklen_t(MemoryLayout<sockaddr_in6>.size)
                    let count = withUnsafeMutablePointer(to: &device) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(near, &buffer, buffer.count, 0, $0, &deviceLength) }
                    }
                    if count > 0 { _ = send(far, buffer, count, 0) }
                }
                if polled[1].revents & Int16(POLLIN) != 0 {
                    let count = recv(far, &buffer, buffer.count, 0)
                    if count > 0, queued + count <= limit, deviceLength > 0 {
                        lastDue = max(now(), lastDue) + Double(count * 8) / bitsPerSecond
                        queue.append((Array(buffer[0..<count]), lastDue))
                        queued += count
                    }
                }
            }
            Darwin.close(near)
            Darwin.close(far)
        }
    }

    func stop() { lock.withLock { running = false } }
}
