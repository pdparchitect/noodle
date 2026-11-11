#if !canImport(os)
import Foundation

/// The unified log's `Logger` where there is none: the same calls write a line to standard error,
/// which a service manager such as systemd keeps. Debug lines are left out.
public struct Logger: Sendable {
    private let label: String

    public init(subsystem: String, category: String) { label = "\(subsystem) \(category)" }

    public func debug(_ message: LogMessage) {}
    public func info(_ message: LogMessage) { write("info", message) }
    public func notice(_ message: LogMessage) { write("notice", message) }
    public func warning(_ message: LogMessage) { write("warning", message) }
    public func error(_ message: LogMessage) { write("error", message) }
    public func fault(_ message: LogMessage) { write("fault", message) }

    private func write(_ level: String, _ message: LogMessage) {
        FileHandle.standardError.write(Data("[\(label)] \(level): \(message.text)\n".utf8))
    }
}

/// What a log line says. Everything in it is written out: there is no log to keep a value private from.
public struct LogMessage: ExpressibleByStringInterpolation, Sendable {
    public enum Privacy: Sendable { case `public`, `private`, auto }

    public struct StringInterpolation: StringInterpolationProtocol, Sendable {
        var text = ""
        public init(literalCapacity: Int, interpolationCount: Int) {}
        public mutating func appendLiteral(_ literal: String) { text += literal }
        public mutating func appendInterpolation<Value>(_ value: Value, privacy: Privacy = .auto) { text += String(describing: value) }
    }

    let text: String
    public init(stringLiteral value: String) { text = value }
    public init(stringInterpolation: StringInterpolation) { text = stringInterpolation.text }
}
#endif
