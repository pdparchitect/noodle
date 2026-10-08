import Foundation

/// What travels on a surface's channel: `surfaceOpened` as JSON first, a game's controls if it
/// has any, then video as binary packets with the companion's status among them, and the
/// viewer's controls going back the other way.
public enum LinkSurface {
    public enum Message: Equatable, Sendable {
        case opened(session: UUID)
        case packets([SurfacePacket])
        case failed(String)
        case controls(Gamepad)
        /// Why the surface shows nothing new, or nil once it does again.
        case notice(SurfaceNotice?)
    }

    /// Packets start with their format byte, never "{" as a JSON event does.
    public static func message(_ frame: Data) -> Message? {
        if frame.first == SurfacePacket.formatByte { return SurfacePacket.decode(frame).map(Message.packets) }
        if let status = SurfaceStatus(frame) { return .notice(status.notice) }
        switch LinkProtocol.decodeEvent(frame) {
        case .surfaceOpened(let session)?: return .opened(session: session)
        case .surfaceFailed(let reason)?: return .failed(reason)
        case .surfaceControls(let controls)?: return .controls(controls)
        default: return nil
        }
    }

    public static func control(_ control: SurfaceControl) -> Data { control.encoded }

    /// Relays a live view between the companion showing it and the device watching it, both
    /// ways and as it happens: video down as the companion encodes it, the person's controls up
    /// in the order they sent them. Video comes only as fast as the device's link takes it, so a
    /// slow link gets less of it rather than getting it late. While the view is open, bots wait.
    public static func relay(_ companion: SurfaceSocket, to stream: LinkStream) {
        let delivery = SurfaceDelivery()
        stream.onFrame { data in
            // How fast the device's link goes is the Hub's to measure, not the device's to say.
            switch SurfaceControl(data) {
            case .shown(let sequence)?:
                // The companion builds recovery frames on what the device has shown.
                delivery.shown(sequence)
                companion.send(data)
            case .rate?, nil: break
            case _?: companion.send(data)
            }
        }
        stream.onClose { companion.close() }
        Task {
            await companion.relay(to: stream.send, backlog: { stream.pendingBytes }, delivery: delivery)
            stream.close()
        }
    }
}
