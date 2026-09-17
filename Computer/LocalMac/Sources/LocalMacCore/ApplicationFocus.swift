import Foundation

/// NSWorkspace can have no frontmost application after a background login.
/// Recover only from an explicit AXFrontmost response by one account-owned
/// candidate; window ordering or a remembered PID does not establish focus.
public enum LocalMacApplicationFocus {
    public struct Candidate {
        public var pid: Int32
        public var layer: Int
        public init(pid: Int32, layer: Int) { self.pid = pid; self.layer = layer }
    }
    public static func resolve(workspacePID: Int32?, candidates: [Candidate],
                               belongsToAccount: (Int32) -> Bool,
                               isFrontmost: (Int32) -> Bool?) -> Int32? {
        if let workspacePID {
            return workspacePID > 0 && belongsToAccount(workspacePID) ? workspacePID : nil
        }
        var seen: Set<Int32> = []
        var focused: Int32?
        // Desktop widgets can report AXFrontmost=true alongside the real app.
        // Only ordinary application windows establish fallback candidates.
        for candidate in candidates where candidate.layer == 0 {
            let pid = candidate.pid
            guard pid > 0, seen.insert(pid).inserted else { continue }
            guard belongsToAccount(pid), isFrontmost(pid) == true else { continue }
            guard focused == nil else { return nil }
            focused = pid
        }
        return focused
    }
}
