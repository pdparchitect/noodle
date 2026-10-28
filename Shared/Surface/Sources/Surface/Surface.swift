import CoreGraphics
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
    /// Files a person watching chose for a page that asked. Empty names means they cancelled.
    /// Bodies here are only the small answers: cancel, too large, or could not send.
    case files(id: UUID, names: [String], bodies: [Data])
    /// One piece of a chosen file. Pieces of one request share `id`. `file` and `part` start at 0.
    case filePart(id: UUID, file: Int, files: Int, part: Int, parts: Int, name: String, body: Data)

    public init?(_ data: Data) {
        guard let control = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = control
    }

    public var encoded: Data { (try? JSONEncoder().encode(self)) ?? Data() }
}

/// A page asked the person watching to choose a file. The picker is on their Mac or iPhone,
/// never on the Mac that is running the browser.
public struct SurfaceFileAsk: Codable, Equatable, Sendable {
    public var id: UUID
    public var multiple: Bool
    public var directories: Bool
    /// The Hub's default largest file. A bigger body is refused.
    public static let byteLimit = 100_000_000
    /// Sent in place of a name when every chosen file was over `byteLimit`.
    public static let tooLarge = "\u{0}"
    /// Sent in place of a name when the file could not be read or could not fit on the channel.
    public static let failed = "\u{1}"

    public init(id: UUID, multiple: Bool, directories: Bool) {
        self.id = id
        self.multiple = multiple
        self.directories = directories
    }

    private enum CodingKeys: String, CodingKey {
        case id = "surfaceFileAsk"
        case multiple = "surfaceFileMultiple"
        case directories = "surfaceFileDirectories"
    }

    public init?(_ data: Data) {
        guard data.first == UInt8(ascii: "{"), let ask = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = ask
    }

    public var encoded: Data { (try? JSONEncoder().encode(self)) ?? Data() }
}

/// Splits chosen files into controls that each fit one live-view frame.
public enum SurfaceFileParts {
    /// Raw bytes in one piece. A piece with a long name still encodes under `SurfaceSocket.frameLimit`.
    public static let rawLimit: Int = {
        let name = String(repeating: "n", count: 255)
        var size = ((SurfaceSocket.frameLimit - 1024) / 4) * 3
        while size > 1024 {
            let part = SurfaceControl.filePart(id: UUID(), file: 99, files: 100, part: 99, parts: 100, name: name, body: Data(count: size))
            if part.encoded.count <= SurfaceSocket.frameLimit { return size }
            size = size * 9 / 10
        }
        return 1024
    }()

    /// Frames for the reply. Nil when a piece cannot fit, which the caller reports as a failure.
    public static func frames(id: UUID, names: [String], bodies: [Data]) -> [Data]? {
        if names.isEmpty || names == [SurfaceFileAsk.tooLarge] || names == [SurfaceFileAsk.failed] {
            let frame = SurfaceControl.files(id: id, names: names, bodies: bodies).encoded
            return frame.count <= SurfaceSocket.frameLimit && !frame.isEmpty ? [frame] : nil
        }
        guard names.count == bodies.count, !names.isEmpty else { return nil }
        var frames: [Data] = []
        for (file, pair) in zip(names, bodies).enumerated() {
            let body = pair.1
            let count = max(1, (body.count + rawLimit - 1) / rawLimit)
            var offset = body.startIndex
            var part = 0
            repeat {
                let end = body.index(offset, offsetBy: rawLimit, limitedBy: body.endIndex) ?? body.endIndex
                let slice = Data(body[offset..<end])
                let frame = SurfaceControl.filePart(id: id, file: file, files: names.count, part: part, parts: count, name: pair.0, body: slice).encoded
                guard !frame.isEmpty, frame.count <= SurfaceSocket.frameLimit else { return nil }
                frames.append(frame)
                offset = end
                part += 1
                if slice.isEmpty { break }
            } while offset < body.endIndex
        }
        return frames
    }
}

/// Reads chosen files without loading one the Hub would refuse, then splits them into frames.
public enum SurfaceFileRead {
    public static func frames(id: UUID, urls: [URL]) -> [Data] {
        func signal(_ name: String) -> [Data] {
            SurfaceFileParts.frames(id: id, names: name.isEmpty ? [] : [name], bodies: name.isEmpty ? [] : [Data()]) ?? []
        }
        if urls.isEmpty { return signal("") }
        var total = 0
        var chosen: [(name: String, url: URL, size: Int)] = []
        for url in urls {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let size = values?.fileSize else { return signal(SurfaceFileAsk.failed) }
            if size > SurfaceFileAsk.byteLimit || total > SurfaceFileAsk.byteLimit - size { return signal(SurfaceFileAsk.tooLarge) }
            total += size
            chosen.append((url.lastPathComponent, url, size))
        }
        var names: [String] = []
        var bodies: [Data] = []
        for item in chosen {
            let access = item.url.startAccessingSecurityScopedResource()
            defer { if access { item.url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: item.url), data.count == item.size else { return signal(SurfaceFileAsk.failed) }
            names.append(item.name)
            bodies.append(data)
        }
        return SurfaceFileParts.frames(id: id, names: names, bodies: bodies) ?? signal(SurfaceFileAsk.failed)
    }
}

/// Where a surface sits in a viewer that shows all of it, keeping its shape.
public enum SurfaceGeometry {
    public static func fitted(_ surface: CGSize, in view: CGSize) -> CGRect {
        guard surface.width > 0, surface.height > 0 else { return .zero }
        let scale = min(view.width / surface.width, view.height / surface.height)
        let size = CGSize(width: surface.width * scale, height: surface.height * scale)
        return CGRect(origin: CGPoint(x: (view.width - size.width) / 2, y: (view.height - size.height) / 2), size: size)
    }

    /// The surface point under `point` of a viewer with a top-left origin. Nil outside the surface.
    public static func surfacePoint(_ point: CGPoint, in view: CGSize, surface: CGSize) -> CGPoint? {
        let frame = fitted(surface, in: view)
        guard frame.width > 0, frame.contains(point) else { return nil }
        return CGPoint(x: (point.x - frame.minX) * surface.width / frame.width,
                       y: (point.y - frame.minY) * surface.height / frame.height)
    }
}

/// How fingers work a live view on iPhone: a tap clicks, a finger drag scrolls, touching and holding
/// then moving drags the pointer, and two fingers zoom into the picture and move around it.
/// Points are in the view, from its top-left corner.
struct SurfaceTouches {
    enum Hold { case began, moved, ended }
    static let deepest: CGFloat = 8

    private var scale: CGFloat = 1
    /// Where the zoomed picture's corner sits in the view.
    private var origin: CGPoint?
    private var holding = false

    /// Where the picture sits in the view, zoomed and kept covering it.
    func frame(_ surface: CGSize, in view: CGSize) -> CGRect {
        let fitted = SurfaceGeometry.fitted(surface, in: view)
        let size = CGSize(width: fitted.width * scale, height: fitted.height * scale)
        let origin = origin ?? fitted.origin
        // Smaller than the view it centres, larger it leaves no gap at either edge.
        func axis(_ at: CGFloat, _ length: CGFloat, _ bound: CGFloat) -> CGFloat {
            length <= bound ? (bound - length) / 2 : min(0, max(bound - length, at))
        }
        return CGRect(x: axis(origin.x, size.width, view.width), y: axis(origin.y, size.height, view.height),
                      width: size.width, height: size.height)
    }

    private func target(_ point: CGPoint, surface: CGSize, view: CGSize) -> CGPoint? {
        let frame = frame(surface, in: view)
        guard frame.width > 0, frame.contains(point) else { return nil }
        return CGPoint(x: (point.x - frame.minX) * surface.width / frame.width, y: (point.y - frame.minY) * surface.height / frame.height)
    }

    func tap(_ point: CGPoint, surface: CGSize, view: CGSize) -> [SurfaceInput] {
        guard let target = target(point, surface: surface, view: view) else { return [] }
        return [.pointer(.down, x: target.x, y: target.y), .pointer(.up, x: target.x, y: target.y)]
    }

    func scroll(_ point: CGPoint, by moved: CGPoint, surface: CGSize, view: CGSize) -> [SurfaceInput] {
        guard let target = target(point, surface: surface, view: view) else { return [] }
        let scale = surface.width / max(1, frame(surface, in: view).width)
        return [.scroll(x: target.x, y: target.y, dx: -moved.x * scale, dy: -moved.y * scale)]
    }

    /// A drag starts on the picture; once it has, it keeps to the picture's edge and always lets go.
    mutating func hold(_ phase: Hold, at point: CGPoint, surface: CGSize, view: CGSize) -> [SurfaceInput] {
        if phase == .began {
            guard let target = target(point, surface: surface, view: view) else { return [] }
            holding = true
            return [.pointer(.down, x: target.x, y: target.y)]
        }
        guard holding else { return [] }
        if phase == .ended { holding = false }
        let frame = frame(surface, in: view)
        guard frame.width > 0 else { return [] }
        let x = min(max(0, (point.x - frame.minX) * surface.width / frame.width), surface.width)
        let y = min(max(0, (point.y - frame.minY) * surface.height / frame.height), surface.height)
        return [.pointer(phase == .ended ? .up : .drag, x: x, y: y)]
    }

    /// Zooms by `factor` keeping what is under `point` there, then moves the picture with the fingers.
    mutating func zoom(by factor: CGFloat, around point: CGPoint, moved: CGPoint, surface: CGSize, view: CGSize) {
        let before = frame(surface, in: view)
        let next = min(max(1, scale * factor), Self.deepest)
        let ratio = next / scale
        scale = next
        origin = CGPoint(x: point.x - (point.x - before.minX) * ratio + moved.x, y: point.y - (point.y - before.minY) * ratio + moved.y)
        origin = frame(surface, in: view).origin
    }

    var zoomed: Bool { scale > 1 }

    /// The pixels the picture needs to look sharp in a view of `view` points on a `screen` scale display.
    func pixels(_ view: CGSize, screen: CGFloat) -> CGSize {
        CGSize(width: view.width * screen * scale, height: view.height * screen * scale)
    }
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
