import ComputerBridge
import Darwin
import Foundation

public enum ComputerAgentFiles {
    /// Foundation's protected atomic write can expose an empty destination while
    /// preparing it. Publish IPC messages only after the complete private file
    /// is ready, so neither scanner nor CLI can claim a partial JSON envelope.
    public static func write<T: Encodable>(_ value: T, to destination: URL) throws {
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".computer-message-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try MCPBridgeFiles.write(value, to: temporary)
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            throw ComputerBridgeError("Cannot publish the Computer bridge message.")
        }
    }
}
