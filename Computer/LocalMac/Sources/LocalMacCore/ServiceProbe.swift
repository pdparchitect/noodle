import Foundation

/// A registered launchd endpoint can exist even when its executable cannot
/// launch. Probe without account operations and bound the wait for that case.
public enum LocalMacServiceProbe {
    public static func responds(_ connection: NSXPCConnection, timeout: TimeInterval = 5) async -> Bool {
        await waitForReply(timeout: timeout) { finish in
            let service = connection.remoteObjectProxyWithErrorHandler { _ in finish(false) } as! LocalMacLifecycle
            service.check { finish(true) }
        }
    }

    static func waitForReply(timeout: TimeInterval, send: (@escaping @Sendable (Bool) -> Void) -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            let reply = ProbeReply(continuation)
            // Retain the continuation until the deadline even if XPC drops its
            // callbacks without reporting an error. Late replies are harmless.
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { reply.finish(false) }
            send { reply.finish($0) }
        }
    }
}

private final class ProbeReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
    func finish(_ value: Bool) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(returning: value)
    }
}
