import Foundation

/// Metadata belongs to the audio attachment, not a second text message.
public struct VoiceMessage: Codable, Hashable, Sendable {
    public let transcript: String?
    public let duration: TimeInterval
    public let waveform: [Float]
    public let localeIdentifier: String?

    public init(transcript: String?, duration: TimeInterval, waveform: [Float], localeIdentifier: String?) {
        let text = transcript?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transcript = text?.isEmpty == false ? text : nil
        self.duration = duration
        self.waveform = waveform
        self.localeIdentifier = localeIdentifier
    }

    public var isValid: Bool {
        duration.isFinite && duration > 0 && duration <= 660 &&
        waveform.count <= 120 && waveform.allSatisfy { $0.isFinite && (0...1).contains($0) } &&
        (transcript?.utf8.count ?? 0) <= 128_000 && (localeIdentifier?.count ?? 0) <= 100
    }

    public static let messageBody = "Voice message"
}
