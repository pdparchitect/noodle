import Foundation

public struct AppletError: Error, LocalizedError, Sendable {
    public let message: String
    public let unavailable: Bool
    public let code: String?
    public init(_ message: String, unavailable: Bool = false, code: String? = nil) {
        self.message = message
        self.unavailable = unavailable
        self.code = code
    }
    public var errorDescription: String? { message }
}

/// Paths a noodlet names inside its own folder or data: relative, and never leaving it.
public enum NoodletPath {
    public static func validate(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
            parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }), path.utf8.count < 2048
        else {
            throw AppletError("Unsafe relative path: \(path.prefix(100))")
        }
    }

    /// `relative` inside `root`, refusing a path that leaves it or passes through a link.
    public static func child(_ relative: String, in root: URL) throws -> URL {
        try validate(relative)
        var current = root
        for component in relative.split(separator: "/") {
            current.appendPathComponent(String(component))
            if let values = try? current.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
                throw AppletError("Symlinks are not allowed inside noodlets: \(relative)")
            }
        }
        return current
    }
}
