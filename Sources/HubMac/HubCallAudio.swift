import Foundation
import HubLink
import NoodleCore

/// Carries a call's audio between the device, as packets on the call's channel, and the bot's
/// voice. Frames come in one at a time from the channel and the voice from the peer's own thread,
/// so each direction has its own codec.
final class HubCallAudio: @unchecked Sendable {
    private let peer: any VoiceCallPeering
    private let decoder: LinkCallDecoder

    init(peer: any VoiceCallPeering, send: @escaping @Sendable (Data) -> Void) throws {
        self.peer = peer
        decoder = try LinkCallDecoder()
        let encoder = try LinkCallEncoder()
        peer.onVoice = { samples in
            for packet in (try? encoder.encode(samples)) ?? [] { send(LinkCallAudio.frame(packet)) }
        }
    }

    func receive(_ frame: Data) {
        guard let packet = LinkCallAudio.packet(in: frame), let samples = try? decoder.decode(packet) else { return }
        peer.hear(samples)
    }
}
