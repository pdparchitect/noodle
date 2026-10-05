import Foundation

/// Asks the Hub to call one of the user's bots. The device captures and plays the audio itself:
/// it goes between the device and the bot's voice service, never through the Hub, which only
/// passes the session descriptions and what is said.
public struct LinkCallStart: Codable, Equatable, Sendable {
    public var conversationID: UUID
    /// The device's WebRTC offer.
    public var offer: String

    public init(conversationID: UUID, offer: String) {
        self.conversationID = conversationID
        self.offer = offer
    }
}

public struct LinkCallLine: Codable, Equatable, Sendable {
    public enum Speaker: String, Codable, Sendable { case you, bot }

    public var speaker: Speaker
    public var text: String
    /// When it was said, so it can be shown among what was typed during the call.
    public var at: Date?

    public init(speaker: Speaker, text: String, at: Date?) {
        self.speaker = speaker
        self.text = text
        self.at = at
    }
}

/// A call as its conversation shows it, on the message that marks where it started.
public struct LinkCallRecord: Codable, Equatable, Sendable {
    public var botID: UUID
    /// Nil while the call is on.
    public var endedAt: Date?
    public var lines: [LinkCallLine]

    public init(botID: UUID, endedAt: Date? = nil, lines: [LinkCallLine] = []) {
        self.botID = botID
        self.endedAt = endedAt
        self.lines = lines
    }

    private enum CodingKeys: String, CodingKey { case botID, endedAt, lines }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        botID = try c.decode(UUID.self, forKey: .botID)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        lines = try c.decode(.lines, or: [])
    }
}

/// What comes down a call's channel, one JSON frame each. Closing the channel hangs up.
public enum LinkCallEvent: Codable, Equatable, Sendable {
    /// The voice service's WebRTC answer to the device's offer.
    case answer(String)
    case started
    case line(LinkCallLine)
    /// The detail is nil when the call ended without an error.
    case ended(String?)

    public var encoded: Data { (try? JSONEncoder().encode(self)) ?? Data() }

    public init?(_ frame: Data) {
        guard let event = try? JSONDecoder().decode(Self.self, from: frame) else { return nil }
        self = event
    }
}

/// The page that captures the microphone and plays the bot's voice on a device, in a hidden
/// web view: WebKit gives every Noodle app WebRTC, echo cancellation and playback. `offer()`
/// returns the WebRTC offer, `answer(sdp)` completes the call, `mute(bool)`, `chime()` and
/// `hangUp()` do as named, and a lost connection posts `{failed: true}` to the `call` handler.
public enum LinkCallMedia {
    /// A secure origin, which the microphone needs.
    public static let baseURL = URL(string: "https://call.noodle.invalid/")

    // The voice model's clock only advances while audio arrives, and WebKit stops
    // sending on digital silence, so a faint noise floor keeps it flowing while muted.
    public static let page = """
    <!doctype html><html><body><audio id="voice" autoplay></audio><script>
    let peer, microphone, context, gain;
    async function offer() {
      microphone = await navigator.mediaDevices.getUserMedia({audio: {echoCancellation: true, noiseSuppression: true, autoGainControl: true}});
      context = new AudioContext();
      await context.resume();
      const destination = context.createMediaStreamDestination();
      gain = context.createGain();
      context.createMediaStreamSource(microphone).connect(gain).connect(destination);
      const noise = context.createBuffer(1, context.sampleRate * 2, context.sampleRate);
      const samples = noise.getChannelData(0);
      for (let i = 0; i < samples.length; i++) samples[i] = (Math.random() * 2 - 1) * 0.002;
      const floor = context.createBufferSource();
      floor.buffer = noise; floor.loop = true; floor.connect(destination); floor.start();
      peer = new RTCPeerConnection();
      destination.stream.getAudioTracks().forEach(track => peer.addTrack(track, destination.stream));
      peer.createDataChannel('oai-events');
      peer.ontrack = event => { const voice = document.getElementById('voice'); voice.srcObject = event.streams[0]; voice.play().catch(() => {}); };
      peer.onconnectionstatechange = () => { if (peer.connectionState === 'failed') window.webkit.messageHandlers.call.postMessage({failed: true}); };
      await peer.setLocalDescription(await peer.createOffer());
      await new Promise(resolve => {
        if (peer.iceGatheringState === 'complete') return resolve();
        peer.onicegatheringstatechange = () => { if (peer.iceGatheringState === 'complete') resolve(); };
        setTimeout(resolve, 3000);
      });
      return peer.localDescription.sdp;
    }
    async function answer(sdp) { await peer.setRemoteDescription({type: 'answer', sdp}); }
    function mute(muted) { if (gain) gain.gain.value = muted ? 0 : 1; }
    // Played on the speakers, not into the call, so the bot never hears it.
    function chime() {
      if (!context) return;
      const start = context.currentTime;
      [[660, 0], [880, 0.13]].forEach(([frequency, offset]) => {
        const tone = context.createOscillator(), level = context.createGain();
        tone.type = 'sine';
        tone.frequency.value = frequency;
        level.gain.setValueAtTime(0, start + offset);
        level.gain.linearRampToValueAtTime(0.18, start + offset + 0.02);
        level.gain.exponentialRampToValueAtTime(0.001, start + offset + 0.28);
        tone.connect(level).connect(context.destination);
        tone.start(start + offset);
        tone.stop(start + offset + 0.3);
      });
    }
    function hangUp() {
      if (peer) peer.close();
      if (microphone) microphone.getTracks().forEach(track => track.stop());
      if (context) context.close();
    }
    </script></body></html>
    """
}
