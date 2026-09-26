import Foundation

/// What travels on a surface's channel: `surfaceOpened` as JSON first, then video as binary
/// packets, and the person's input going back the other way.
public enum LinkSurface {
    public enum Message: Equatable, Sendable {
        case opened(session: UUID)
        case packets([SurfacePacket])
    }

    /// Most of a stream frame, so a key frame never meets the link's limit.
    static let batchBytes = 900_000

    public static func frame(_ packets: [SurfacePacket]) -> Data { SurfacePacket.encode(packets) }

    /// Packets grouped so each group fits one frame.
    public static func batches(_ packets: [SurfacePacket]) -> [[SurfacePacket]] {
        var batches: [[SurfacePacket]] = [], current: [SurfacePacket] = [], bytes = 0
        for packet in packets {
            let size = packet.sample.count + packet.parameterSets.reduce(0) { $0 + $1.count } + 64
            if !current.isEmpty, bytes + size > batchBytes { batches.append(current); current = []; bytes = 0 }
            current.append(packet)
            bytes += size
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    /// Packets start with their format byte, never "{" as a JSON event does.
    public static func message(_ frame: Data) -> Message? {
        if frame.first == SurfacePacket.formatByte { return SurfacePacket.decode(frame).map(Message.packets) }
        if case .surfaceOpened(let session)? = LinkProtocol.decodeEvent(frame) { return .opened(session: session) }
        return nil
    }

    public static func input(_ input: SurfaceInput) -> Data { (try? JSONEncoder().encode(input)) ?? Data() }
}
