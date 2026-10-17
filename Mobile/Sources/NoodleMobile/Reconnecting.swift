import Foundation
import Network
import Synchronization

/// How long to wait before connecting to a Hub again: twice as long after each failure, from a
/// second up to half a minute, each wait cut by a random part so phones that lost the Hub together
/// do not all come back at once.
struct HubBackoff: Sendable {
    static let first: Duration = .seconds(1)
    static let longest: Duration = .seconds(30)
    /// The part of each wait that is kept, from half of it to all of it.
    private let jitter: @Sendable () -> Double
    private var failures = 0

    init(jitter: @escaping @Sendable () -> Double = { .random(in: 0.5...1) }) {
        self.jitter = jitter
    }

    mutating func next() -> Duration {
        let full = min(Self.longest, Self.first * (1 << min(failures, 16)))
        failures += 1
        return full * jitter()
    }

    mutating func reset() { failures = 0 }
}

/// Wakes whoever waits on it at the moment; a wake with nobody waiting is lost. Unlike an
/// AsyncStream, which ends for good once one wait on it is cancelled, it can be waited on again.
@MainActor final class Wakes {
    private var waiting: [UUID: CheckedContinuation<Void, Never>] = [:]

    func next() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() } else { waiting[id] = continuation }
            }
        } onCancel: {
            Task { @MainActor in self.waiting.removeValue(forKey: id)?.resume() }
        }
    }

    func wake() {
        let woken = waiting
        waiting = [:]
        woken.values.forEach { $0.resume() }
    }
}

/// Each time the phone's way onto the network changes while it is online: it comes online, or
/// moves between Wi-Fi, mobile data and VPNs such as Tailscale.
enum NetworkChanges {
    static func live() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let monitor = NWPathMonitor()
            let last = Mutex<Way?>(nil)
            monitor.pathUpdateHandler = { path in
                let way = Way(path)
                let changed = last.withLock { last in
                    defer { last = way }
                    return last != nil && last != way
                }
                if changed, way.isOnline { continuation.yield() }
            }
            continuation.onTermination = { _ in monitor.cancel() }
            monitor.start(queue: DispatchQueue(label: "NetworkChanges"))
        }
    }

    private struct Way: Equatable {
        let isOnline: Bool
        let interfaces: [String]

        init(_ path: NWPath) {
            isOnline = path.status == .satisfied
            interfaces = path.availableInterfaces.map(\.name)
        }
    }
}
