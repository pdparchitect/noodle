import AppKit
import NoodleCore
import SwiftUI

/// What the call views need from the app that shows them.
@MainActor protocol VoiceCallHost: AnyObject {
    var voiceCalls: VoiceCallController { get }
    /// The bot a conversation's call goes to, or nil when it has none.
    func voiceCallTarget(for conversation: BotConversation) -> AgentRecord?
    func canCallNow(in conversation: BotConversation) -> Bool
    func startCall(in conversation: BotConversation)
    /// The card of the call in progress in a conversation.
    func liveCallCardID(in conversationID: UUID) -> UUID?
    func callerName(_ agentID: UUID) -> String?
}

/// The call button, or while this conversation is on a call, its controls.
/// The chat stays free during a call; what is said shows on the call's card.
struct VoiceCallToolbarControl: View {
    let store: any VoiceCallHost
    let conversation: BotConversation

    var body: some View {
        if let call = store.voiceCalls.call, call.conversationID == conversation.id {
            ongoing(call)
        } else if let agent = store.voiceCallTarget(for: conversation) {
            Button { store.startCall(in: conversation) } label: {
                Label("Call", systemImage: "phone")
            }
            .help("Call \(agent.displayName)")
            // A message waits for the bot; a call needs it running now.
            .disabled(!store.canCallNow(in: conversation))
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

/// Where a call starts in its conversation: live while it runs, then its length. What was
/// said follows it as speech bubbles, among whatever was sent during the call.
struct VoiceCallCard: View {
    let store: any VoiceCallHost
    let message: ChatMessage
    let record: VoiceCallRecord

    var body: some View {
        let live = store.liveCallCardID(in: message.conversationID) == message.id ? store.voiceCalls.call : nil
        HStack {
            Spacer(minLength: 60)
            HStack(spacing: 10) {
                Image(systemName: record.unanswered != nil ? "phone.arrow.down.left" : live == nil ? "phone" : "phone.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(record.unanswered != nil ? Color.red : live == nil ? Color.secondary : Color.green)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                    Group {
                        if record.unanswered != nil {
                            if let reason = record.reason { Text(reason).lineLimit(2) }
                        } else if let live {
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
            Spacer(minLength: 60)
        }
    }

    private var title: String {
        switch record.unanswered {
        case .missed: "Missed call from \(botName)"
        case .declined: "Declined call from \(botName)"
        case nil: "Voice call with \(botName)"
        }
    }

    private var botName: String {
        store.callerName(record.agentID) ?? "Bot"
    }
}

/// One stretch of a call between two messages.
struct VoiceCallBlock: Equatable {
    let agentID: UUID
    var lines: [VoiceCallLine]
    let isLive: Bool
}

/// A stretch of what was said on a call, kept to a two-line preview so a long call stays
/// compact. Clicking it shows the whole stretch.
struct VoiceCallBlockView: View {
    let store: any VoiceCallHost
    let block: VoiceCallBlock
    @State private var showsAll = false

    var body: some View {
        // A live block follows the conversation; a finished one reads from its start.
        let preview = block.isLive ? Array(block.lines.suffix(2)) : Array(block.lines.prefix(2))
        HStack {
            Spacer(minLength: 60)
            Button { showsAll = true } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "waveform")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(preview.enumerated()), id: \.offset) { _, line in
                            (Text(speaker(line) + "  ").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                                + Text(line.text).font(.system(size: 12.5)))
                                .lineLimit(1)
                        }
                        if block.lines.count > preview.count {
                            Text("\(block.lines.count) lines")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: 380, alignment: .leading)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .contentShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .help("Show what was said")
            .popover(isPresented: $showsAll, arrowEdge: .bottom) {
                VoiceCallTranscript(lines: block.lines, botName: botName)
            }
            Spacer(minLength: 60)
        }
    }

    private var botName: String { store.callerName(block.agentID) ?? "Bot" }
    private func speaker(_ line: VoiceCallLine) -> String { line.speaker == .person ? "You" : botName }
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
        // Keep the scrollbar clear of the popover's rounded corners.
        .contentMargins(.vertical, 16, for: .scrollIndicators)
        .frame(width: 340, height: 300)
    }
}

enum VoiceCallLayout {
    /// Each spoken line goes after the last message sent before it was said, but never
    /// above its own call, so messages sent during a call split its transcript into blocks.
    /// Lines without a time stay with their call.
    static func spokenLines(in messages: [ChatMessage], live: (messageID: UUID, lines: [VoiceCallLine])?) -> [UUID: VoiceCallBlock] {
        var placed: [UUID: VoiceCallBlock] = [:]
        for (index, card) in messages.enumerated() {
            guard let record = card.call else { continue }
            let isLive = live?.messageID == card.id
            for line in isLive ? live?.lines ?? [] : record.lines {
                var host = index
                if let at = line.at {
                    while host + 1 < messages.count, messages[host + 1].createdAt <= at { host += 1 }
                }
                placed[messages[host].id, default: VoiceCallBlock(agentID: record.agentID, lines: [], isLive: isLive)].lines.append(line)
            }
        }
        return placed
    }
}

/// Call or End Call in the Conversation menu, in every app. Holding its shortcut must not end the call it just
/// started.
struct CallCommandButton: View {
    let isOnCall: Bool
    let toggle: () -> Void

    var body: some View {
        Button(isOnCall ? "End Call" : "Call") {
            if let event = NSApp.currentEvent, event.type == .keyDown, event.isARepeat { return }
            toggle()
        }
        .appShortcut(.call)
    }
}
