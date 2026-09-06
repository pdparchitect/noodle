import Foundation

/// Frames and decodes process output away from the main thread. Only incoming
/// bytes are scanned; a large partial response is never rescanned on each read.
public final class JSONLineReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Noodle.process-output", qos: .utility)
    private var pending = Data()
    private let onMessage: @Sendable ([String: Any]) -> Void

    public init(onMessage: @escaping @Sendable ([String: Any]) -> Void) {
        self.onMessage = onMessage
    }

    public func receive(_ data: Data) {
        queue.async { [self] in
            var start = data.startIndex
            for index in data.indices where data[index] == 0x0A {
                pending.append(contentsOf: data[start..<index])
                if !pending.isEmpty,
                   let message = try? JSONSerialization.jsonObject(with: pending) as? [String: Any] {
                    onMessage(message)
                }
                pending.removeAll(keepingCapacity: true)
                start = data.index(after: index)
            }
            pending.append(contentsOf: data[start...])
        }
    }
}
