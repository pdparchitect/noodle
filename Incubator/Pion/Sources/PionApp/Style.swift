import AppKit
import NoodleCore
import PionCore
import SwiftUI

// Pion is monochrome: black and white with the system's shading. Colour is kept for what needs
// attention: critical severity, an agent working or stopped.

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

extension Investigation {
    /// The secondary colour until the lead assesses it.
    var severityColor: Color { severity?.color ?? .secondary }
    /// Unassessed first, then low to critical, for sorting.
    var severityRank: Int { severity.map { Severity.allCases.firstIndex(of: $0)! + 1 } ?? 0 }
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

/// A severity as a small bar of up to four steps, readable at a glance in a list; all empty while unassessed.
struct SeverityGlyph: View {
    let severity: Investigation.Severity?
    var closed = false

    var body: some View {
        let level = severity.map { Investigation.Severity.allCases.firstIndex(of: $0)! + 1 } ?? 0
        let color = severity?.color ?? .secondary
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(1...4, id: \.self) { step in
                RoundedRectangle(cornerRadius: 1)
                    .fill(step <= level ? (closed ? Color.secondary.opacity(0.6) : color.opacity(severity == .critical ? 1 : 0.75))
                          : Color.primary.opacity(0.12))
                    .frame(width: 3, height: CGFloat(4 + step * 2))
            }
        }
        .frame(width: 18, height: 12, alignment: .bottomLeading)
        .help(severity.map { "\($0.title) severity" } ?? "Severity unassessed")
        .accessibilityLabel(severity.map { "\($0.title) severity" } ?? "Severity unassessed")
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

/// An agent's mark: its generated sigil.
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
        AgentSigil(seed: agent?.id, size: size)
    }
}

/// An arc that turns around a working agent's mark. Core Animation turns it in the render server, so
/// any number of working agents cost the main thread nothing per frame.
private struct WorkingRing: NSViewRepresentable {
    let lineWidth: CGFloat
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> RingView { RingView() }

    func updateNSView(_ view: RingView, context: Context) {
        view.configure(lineWidth: lineWidth, color: (colorScheme == .dark ? NSColor.white : .black).withAlphaComponent(0.85),
                       turning: !reduceMotion)
    }

    final class RingView: NSView {
        private let arc = CAShapeLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            arc.fillColor = nil
            arc.lineCap = .round
            arc.strokeEnd = 0.28
            layer?.addSublayer(arc)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func configure(lineWidth: CGFloat, color: NSColor, turning: Bool) {
            arc.lineWidth = lineWidth
            arc.strokeColor = color.cgColor
            if turning, arc.animation(forKey: "turn") == nil {
                let turn = CABasicAnimation(keyPath: "transform.rotation.z")
                // Clockwise, as the SwiftUI ring turned: negative in a layer's flipped-up coordinates.
                turn.fromValue = 0
                turn.toValue = -2 * Double.pi
                turn.duration = 1.1
                turn.repeatCount = .infinity
                turn.isRemovedOnCompletion = false
                arc.add(turn, forKey: "turn")
            } else if !turning {
                arc.removeAnimation(forKey: "turn")
            }
            needsLayout = true
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            arc.frame = bounds
            let inset = arc.lineWidth / 2
            arc.path = CGPath(ellipseIn: bounds.insetBy(dx: inset, dy: inset), transform: nil)
            CATransaction.commit()
        }
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

    /// 15:12, the time alone on the 24-hour clock.
    var pionTime: String { Self.time.string(from: self) }

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

/// Puts plain text on the pasteboard, as every Copy in Pion's menus does.
@MainActor func copyText(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
