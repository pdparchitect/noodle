import Foundation

/// What travels on a surface's channel: `surfaceOpened` as JSON first, then video as binary
/// packets, and the viewer's controls going back the other way.
public enum LinkSurface {
    public enum Message: Equatable, Sendable {
        case opened(session: UUID)
        case packets([SurfacePacket])
    }

    /// Packets start with their format byte, never "{" as a JSON event does.
    public static func message(_ frame: Data) -> Message? {
        if frame.first == SurfacePacket.formatByte { return SurfacePacket.decode(frame).map(Message.packets) }
        if case .surfaceOpened(let session)? = LinkProtocol.decodeEvent(frame) { return .opened(session: session) }
        return nil
    }

    public static func control(_ control: SurfaceControl) -> Data { control.encoded }
}
