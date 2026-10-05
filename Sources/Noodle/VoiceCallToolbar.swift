import NoodleCore
import SwiftUI

/// The call button, or while this conversation is on a call, its controls.
/// The chat stays free during a call; what is said shows on the call's card.
struct VoiceCallToolbarControl: View {
    @Environment(NoodleStore.self) private var store
    let conversation: BotConversation

    var body: some View {
        if let call = store.voiceCalls.call, call.conversationID == conversation.id {
            ongoing(call)
        } else if let agent = store.voiceCallTarget(for: conversation) {
            Button { store.startVoiceCall(in: conversation) } label: {
                Label("Call", systemImage: "phone")
            }
            .help("Call \(agent.displayName)")
        }
    }

    /// Every part keeps its width, so the toolbar never moves while the call runs.
    private func ongoing(_ call: VoiceCallController.Call) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "phone.fill")
                    .foregroundStyle(call.startedAt == nil ? Color.secondary : Color.green)
                VoiceCallTimer(startedAt: call.startedAt)
            }
            .help(call.startedAt == nil ? "Connecting" : "On a call")

            Button { store.voiceCalls.toggleMute() } label: {
                Label(call.isMuted ? "Unmute" : "Mute", systemImage: call.isMuted ? "mic.slash.fill" : "mic.fill")
                    .frame(width: 18)
            }
            .labelStyle(.iconOnly)
            .help(call.isMuted ? "Unmute" : "Mute")

            Button { store.voiceCalls.hangUp() } label: {
                Label("End Call", systemImage: "phone.down.fill")
                    .frame(width: 18)
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(.red)
            .help("End Call")
        }
        .padding(.horizontal, 6)
    }
}

/// Elapsed time in a slot as wide as "00:00", dashes until the call connects.
struct VoiceCallTimer: View {
    let startedAt: Date?

    var body: some View {
        ZStack(alignment: .trailing) {
            Text("00:00").hidden()
            if let startedAt {
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text(Self.format(context.date.timeIntervalSince(startedAt)))
                }
            } else {
                Text("--:--")
            }
        }
        .monospacedDigit()
    }

    static func format(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let hours = seconds / 3600, minutes = seconds / 60 % 60, rest = seconds % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%02d:%02d", minutes, rest)
    }
}

/// A call's place in its conversation: live while it runs, then its length and transcript.
struct VoiceCallCard: View {
    @Environment(NoodleStore.self) private var store
    let message: ChatMessage
    let record: VoiceCallRecord
    @State private var showsTranscript = false

    var body: some View {
        let live = store.voiceCalls.call.flatMap { $0.messageID == message.id ? $0 : nil }
        let lines = live?.lines ?? record.lines
        let canShowTranscript = live != nil || !lines.isEmpty
        HStack {
            Spacer(minLength: 60)
            Button { showsTranscript = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: live == nil ? "phone" : "phone.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(live == nil ? Color.secondary : Color.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Voice call with \(botName)")
                            .font(.system(size: 12.5, weight: .medium))
                        Group {
                            if let live {
                                VoiceCallTimer(startedAt: live.startedAt)
                            } else if let endedAt = record.endedAt {
                                Text(Duration.seconds(max(0, endedAt.timeIntervalSince(message.createdAt)))
                                    .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))
                            }
                        }
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .contentShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .allowsHitTesting(canShowTranscript)
            .help(canShowTranscript ? "Show Transcript" : "")
            .popover(isPresented: $showsTranscript, arrowEdge: .bottom) {
                VoiceCallTranscript(lines: lines, botName: botName)
            }
            Spacer(minLength: 60)
        }
    }

    private var botName: String {
        store.agents.first { $0.id == record.agentID }?.displayName ?? "Bot"
    }
}

struct VoiceCallTranscript: View {
    let lines: [VoiceCallLine]
    let botName: String

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.speaker == .person ? "You" : botName)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(line.text).textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
        .defaultScrollAnchor(.bottom)
        .frame(width: 340, height: 300)
        .overlay {
            if lines.isEmpty { Text("Nothing said yet").foregroundStyle(.secondary) }
        }
    }
}
