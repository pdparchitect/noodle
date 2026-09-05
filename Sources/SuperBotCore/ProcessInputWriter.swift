import Foundation

/// Keeps a slow or stalled child process from blocking the application's UI.
/// A serial queue preserves JSON-RPC message order.
public final class ProcessInputWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "SuperBot.process-input", qos: .utility)

    public init(handle: FileHandle) {
        self.handle = handle
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
