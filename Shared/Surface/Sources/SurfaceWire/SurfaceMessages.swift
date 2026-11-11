import Foundation

/// What a person does to a surface, in the surface's points.
public enum SurfaceInput: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case move, down, drag, up }
    public enum Key: String, Codable, Sendable {
        case enter, tab, escape, backspace, space, left, right, up, down
    }
    case pointer(Phase, x: Double, y: Double, clickCount: Int = 1)
    case scroll(x: Double, y: Double, dx: Double, dy: Double)
    case key(Key)
    case text(String)
    /// A key held down or let go, as a game reads it: a named key, a lowercase letter or a digit.
    case hold(key: String, pressed: Bool)
}

/// What travels up a live view, from the viewer to the surface: what the person does, how many
/// pixels the viewer shows it at, so video is never sent larger, or a request to start again at
/// a key frame after missing some.
public enum SurfaceControl: Codable, Equatable, Sendable {
    case input(SurfaceInput)
    case view(width: Double, height: Double)
    case keyFrame
    case rate(bitsPerSecond: Double)
    case shown(sequence: UInt64)
    /// Frames were skipped, but the viewer can still decode on from those it has shown.
    case recover

    public init?(_ data: Data) {
        guard let control = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = control
    }

    public var encoded: Data { (try? JSONEncoder().encode(self)) ?? Data() }
}

/// Why a surface shows nothing new: its page has not drawn yet, or is too busy to answer.
public enum SurfaceNotice: String, Codable, Equatable, Sendable {
    case starting, notResponding

    public var title: String {
        switch self {
        case .starting: "Starting…"
        case .notResponding: "Not responding"
        }
    }
}

/// What a companion says down a live view besides video, as JSON: why its surface shows nothing
/// new, or nil once it does again.
public struct SurfaceStatus: Codable, Equatable, Sendable {
    public var notice: SurfaceNotice?

    public init(notice: SurfaceNotice?) { self.notice = notice }

    /// The key is always there, null for no notice, so no other JSON on the channel reads as a status.
    private enum CodingKeys: String, CodingKey { case notice = "surfaceNotice" }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.notice) else {
            throw DecodingError.keyNotFound(CodingKeys.notice, .init(codingPath: [], debugDescription: "Not a status."))
        }
        notice = try container.decodeIfPresent(SurfaceNotice.self, forKey: .notice)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(notice, forKey: .notice)
    }

    public init?(_ data: Data) {
        guard data.first == UInt8(ascii: "{"), let status = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = status
    }

    public var encoded: Data { (try? JSONEncoder().encode(self)) ?? Data() }
}
