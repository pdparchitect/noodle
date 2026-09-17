import Darwin
import Foundation

/// Keeps a slow or stalled child process from blocking the application's UI.
/// A serial queue preserves JSON-RPC message order.
public final class ProcessInputWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "Noodle.process-input", qos: .utility)

    /// Configure an open writable handle before queuing any requests.
    public init(handle: FileHandle) {
        self.handle = handle
        // An exited child must report a write error, not terminate the parent
        // with SIGPIPE. Configure only this descriptor, not the whole process.
        _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
    }

    public func write(_ data: Data, onFailure: @escaping @Sendable (Error) -> Void) {
        queue.async { [handle] in
            do {
                try handle.write(contentsOf: data)
            } catch {
                onFailure(error)
            }
        }
    }
}
