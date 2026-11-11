// Only the macOS Agent Host uses this.
#if canImport(XPC)
import Foundation
import XPC

/// Keeps the Agent Host out of the idle-exit pool while it runs a harness.
/// Between XPC messages a service without an open transaction counts as idle,
/// and under memory pressure jetsam kills it along with the harness it hosts.
public final class HostActivity: @unchecked Sendable {
    public static let shared = HostActivity(begin: { xpc_transaction_begin() }, end: { xpc_transaction_end() })

    private let begin: () -> Void
    private let end: () -> Void
    private let lock = NSLock()
    private var holds = 0

    public init(begin: @escaping () -> Void, end: @escaping () -> Void) {
        self.begin = begin
        self.end = end
    }

    /// The host stays busy until every hold is released or deallocated.
    public func hold() -> Hold {
        lock.withLock {
            holds += 1
            if holds == 1 { begin() }
        }
        return Hold(self)
    }

    fileprivate func release() {
        lock.withLock {
            holds -= 1
            if holds == 0 { end() }
        }
    }

    public final class Hold: @unchecked Sendable {
        private let lock = NSLock()
        private var activity: HostActivity?

        fileprivate init(_ activity: HostActivity) { self.activity = activity }

        public func release() {
            lock.withLock { () -> HostActivity? in
                defer { activity = nil }
                return activity
            }?.release()
        }

        deinit { release() }
    }
}
#endif
