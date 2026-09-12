import SwiftUI
import NoodleCore

/// Bots working on a reply in the open conversation, shown above the composer.
struct TypingIndicator: View {
    let agents: [AgentRecord]

    var body: some View {
        HStack(spacing: 7) {
            HStack(spacing: -6) {
                ForEach(agents.prefix(3)) { agent in
                    BotAvatar(agent: agent, size: 18, showsShadow: false)
                }
            }
            TypingDots()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .modifier(TypingIndicatorBackground())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    private var label: String {
        let first = agents.first?.displayName ?? ""
        return switch agents.count {
        case 1: "\(first) is typing…"
        case 2: "\(first) and \(agents[1].displayName) are typing…"
        default: "\(first) and \(agents.count - 1) others are typing…"
        }
    }
}

private struct TypingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .frame(width: 5, height: 5)
                        .opacity(reduceMotion ? 0.6 : opacity(at: time, index: index))
                }
            }
        }
        .foregroundStyle(.secondary)
    }

    private func opacity(at time: TimeInterval, index: Int) -> Double {
        let wave = sin(time * 2 * .pi / 1.2 - Double(index) * 0.9)
        return 0.3 + 0.7 * (wave + 1) / 2
    }
}

private struct TypingIndicatorBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: Capsule())
        } else {
            content
        }
    }
}
