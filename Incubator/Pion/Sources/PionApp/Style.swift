import NoodleCore
import PionCore
import SwiftUI

// Pion is monochrome: black and white with the system's shading. Colour is kept for what needs
// attention: an action waiting for the champion, critical severity, an agent working or stopped.

extension Investigation.Status {
    var color: Color { .secondary }

    var symbol: String {
        switch self {
        case .open: "circle"
        case .triaging: "circle.lefthalf.filled"
        case .contained: "shield.lefthalf.filled"
        case .closed: "checkmark.circle"
        }
    }
}

extension Investigation.Severity {
    var color: Color { self == .critical ? .red : .primary }
}

extension ActionPolicy.Mode {
    var color: Color { self == .approval ? .orange : .secondary }
}

extension CaseRecord.ProposedAction.State {
    var color: Color { self == .pending ? .orange : .secondary }
}

extension AgentRuntimePhase {
    var color: Color {
        switch self {
        case .working: .green
        case .ready, .starting, .offline: .secondary
        case .failed: .red
        }
    }

    var title: String {
        switch self {
        case .working: "Working"
        case .ready: "Ready"
        case .starting: "Starting"
        case .failed: "Stopped"
        case .offline: "Offline"
        }
    }
}

/// A severity as a small bar of up to four steps, readable at a glance in a list.
struct SeverityGlyph: View {
    let severity: Investigation.Severity
    var closed = false

    var body: some View {
        let level = Investigation.Severity.allCases.firstIndex(of: severity)! + 1
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(1...4, id: \.self) { step in
                RoundedRectangle(cornerRadius: 1)
                    .fill(step <= level ? (closed ? Color.secondary.opacity(0.6) : severity.color.opacity(severity == .critical ? 1 : 0.75))
                          : Color.primary.opacity(0.12))
                    .frame(width: 3, height: CGFloat(4 + step * 2))
            }
        }
        .frame(width: 18, height: 12, alignment: .bottomLeading)
        .help("\(severity.title) severity")
        .accessibilityLabel("\(severity.title) severity")
    }
}

/// A small capsule label.
struct Tag: View {
    let text: String
    let color: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).imageScale(.small) }
            Text(text)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .foregroundStyle(color == .secondary ? Color.secondary : color)
        .background(color == .secondary ? Color.primary.opacity(0.07) : color.opacity(0.14), in: .capsule)
        .fixedSize()
    }
}

/// An agent's mark: its symbol, or its initial, on a neutral disc shaded for the system's appearance.
/// As Noodle's bot pictures: circled while the agent works, with a red dot once stopped, greyed while offline.
struct AgentMark: View {
    let agent: AgentRecord?
    var size: CGFloat = 22
    var phase: AgentRuntimePhase?

    var body: some View {
        let ring = max(1, size * 0.07)
        disc
            .opacity(phase == .offline ? 0.45 : 1)
            .overlay {
                if phase == .working { WorkingRing(lineWidth: ring).padding(-(ring / 2 + max(1, size * 0.06))) }
            }
            .overlay(alignment: .bottomTrailing) {
                if phase == .failed {
                    Circle().fill(.red).frame(width: max(6, size * 0.3), height: max(6, size * 0.3))
                        .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        .offset(x: 1, y: 1)
                }
            }
            .accessibilityLabel(phase.map { "\(agent?.displayName ?? "Agent"), \($0.title)" } ?? agent?.displayName ?? "Agent")
    }

    private var disc: some View {
        Circle()
            .fill(LinearGradient(colors: [Color.primary.opacity(0.16), Color.primary.opacity(0.06)], startPoint: .top, endPoint: .bottom))
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
            .frame(width: size, height: size)
            .overlay {
                if let symbol = agent?.avatarSymbolName {
                    Image(systemName: symbol).font(.system(size: size * 0.44, weight: .medium)).foregroundStyle(.primary.opacity(0.8))
                } else {
                    Text(agent?.displayName.first.map(String.init) ?? "?")
                        .font(.system(size: size * 0.48, weight: .semibold)).foregroundStyle(.primary.opacity(0.8))
                }
            }
    }
}

/// An arc that turns around a working agent's mark. The turn is read from the clock, as Noodle's is, so
/// it never replays a move the mark makes as the ring appears.
private struct WorkingRing: View {
    let lineWidth: CGFloat

    var body: some View {
        TimelineView(.animation) { context in
            Circle()
                .trim(from: 0, to: 0.28)
                .stroke(Color.primary.opacity(0.85), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1 * 360))
        }
        .accessibilityHidden(true)
    }
}

/// The strongest button in a view, black on white or white on black with the system's appearance.
struct ProminentButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
            .background(Color.primary.opacity(!isEnabled ? 0.3 : configuration.isPressed ? 0.7 : 1), in: .capsule)
    }
}

extension Date {
    /// 15:12 today, Tue 15:12 within a week, or 4 Nov 15:12, always on the 24-hour clock as incident timelines are kept.
    var pionShort: String {
        let now = Date()
        let formatter = Calendar.current.isDate(self, inSameDayAs: now) ? Self.time
            : abs(timeIntervalSince(now)) < 6 * 86_400 ? Self.weekdayTime : Self.dayTime
        return formatter.string(from: self)
    }

    private static func formatter(_ template: String) -> DateFormatter {
        let formatter = DateFormatter()
        // HH in the template asks for the 24-hour clock whatever the locale prefers.
        formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: template, options: 0, locale: .current)
        return formatter
    }

    private static let time = formatter("HHmm")
    private static let weekdayTime = formatter("EEEHHmm")
    private static let dayTime = formatter("dMMMHHmm")
}
