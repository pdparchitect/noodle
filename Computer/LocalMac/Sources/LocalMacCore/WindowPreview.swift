import Foundation

public enum LocalMacWindowCaptureLimits {
    public static let maximumWindows = 32
    public static func scale(bounds: CGRect, nativeScale: CGFloat, count: Int) -> CGFloat {
        guard bounds.width > 0, bounds.height > 0 else { return 1 }
        let pixels = 16_777_216 / CGFloat(max(1, count))
        return min(max(1, nativeScale), 8192 / max(bounds.width, bounds.height),
                   sqrt(pixels / (bounds.width * bounds.height)))
    }
}

public struct LocalMacWindow: Codable, Equatable, Sendable {
    public var id: UInt32
    public var pid: Int32
    public var title: String
    public var application: String
    public init(id: UInt32, pid: Int32, title: String, application: String) {
        self.id = id; self.pid = pid; self.title = title; self.application = application
    }
    public var label: String { title.isEmpty ? application : title }
    public func hasSameIdentity(as other: Self) -> Bool { id == other.id && pid == other.pid }
}

/// Geometry travels with the pixels, never in a separately polled status reply.
public struct LocalMacWindowFrame: Codable, Equatable, Sendable {
    public var previewID: UUID
    public var geometryID: UUID
    public var bounds: CGRect
    public var width: Int
    public var height: Int
    public init(previewID: UUID, geometryID: UUID = UUID(), bounds: CGRect, width: Int, height: Int) {
        self.previewID = previewID; self.geometryID = geometryID; self.bounds = bounds
        self.width = width; self.height = height
    }
    public var display: LocalMacDisplay { .init(width: width, height: height) }
}

/// Resolve public Accessibility geometry against this session's window list.
/// Refuse ambiguous matches rather than choosing an unrelated app window.
public enum LocalMacWindowMatch {
    public struct Candidate {
        public var id: UInt32
        public var pid: Int32
        public var title: String
        public var bounds: CGRect
        public init(id: UInt32, pid: Int32, title: String, bounds: CGRect) {
            self.id = id; self.pid = pid; self.title = title; self.bounds = bounds
        }
    }
    public static func find(pid: Int32, title: String, bounds: CGRect, in candidates: [Candidate]) -> UInt32? {
        let matches = candidates.filter {
            $0.id != 0 && $0.pid == pid && abs($0.bounds.minX - bounds.minX) < 2 &&
            abs($0.bounds.minY - bounds.minY) < 2 && abs($0.bounds.width - bounds.width) < 2 &&
            abs($0.bounds.height - bounds.height) < 2
        }
        if matches.count == 1 { return matches[0].id }
        let titled = matches.filter { !title.isEmpty && $0.title == title }
        return titled.count == 1 ? titled[0].id : nil
    }
}
