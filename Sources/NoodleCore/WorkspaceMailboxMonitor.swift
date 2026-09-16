import Foundation

/// A scan hint, never an authorization boundary. Brokers still open and validate
/// the current mailbox before every operation. Vnode events avoid idle directory
/// walks; periodic reattachment also catches replaced parents and missed events.
public final class WorkspaceMailboxMonitor: @unchecked Sendable {
    private struct Watch {
        var source: DispatchSourceFileSystemObject?
        var changed = true
        var attachedAt: TimeInterval
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "Noodle.mailbox-changes", qos: .utility)
    private var watches: [URL: Watch] = [:]
    private let rescanInterval: TimeInterval

    public init(rescanInterval: TimeInterval = 5) {
        self.rescanInterval = rescanInterval
    }

    deinit { reset() }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        for watch in watches.values { watch.source?.cancel() }
        watches.removeAll()
    }

    /// Check before rebuilding per-bot workspace URLs in the polling loops.
    public func hasChanges(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return watches.isEmpty || watches.values.contains {
            $0.changed || now - $0.attachedAt >= rescanInterval
        }
    }

    public func needsScan(workspace: URL, path: String,
                          now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        let url = workspace.appendingPathComponent(path, isDirectory: true)
        lock.lock()
        defer { lock.unlock() }
        if let watch = watches[url], now - watch.attachedAt < rescanInterval {
            guard watch.changed else { return false }
            watches[url]?.changed = false
            return true
        }
        watches[url]?.source?.cancel()
        let mailbox = try? WorkspaceMailbox(workspace: workspace, path: path)
        let source = try? mailbox?.observeChanges(on: queue) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.watches[url]?.changed = true
            self.lock.unlock()
        }
        watches[url] = Watch(source: source, changed: false, attachedAt: now)
        return true
    }
}
