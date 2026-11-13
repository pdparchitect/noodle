import NoodleCore
import SwiftUI

/// An agent's generated mark: arcs on two or three rings around a small core, on a graphite disc.
/// Each ring is mirrored about the vertical axis, so every mark reads as designed rather than
/// random, and it is drawn from the agent's identity, so a rename never changes it.
struct AgentSigil: View {
    let seed: UUID?
    let size: CGFloat

    var body: some View {
        let design = Design(seed: seed)
        // Small marks keep the two outer rings, drawn heavier, so they stay legible in a list.
        let compact = size < 30
        Canvas { context, canvas in
            let radius = canvas.width / 2
            let centre = CGPoint(x: radius, y: radius)
            for ring in design.rings.prefix(compact ? 2 : 3) {
                let width = radius * ring.weight * (compact ? 1.45 : 1)
                for arc in ring.arcs {
                    // Each arc and its mirror image, measured clockwise from the top.
                    for side in [1.0, -1.0] {
                        var path = Path()
                        let from = -Double.pi / 2 + side * arc.start, to = -Double.pi / 2 + side * (arc.start + arc.length)
                        path.addArc(center: centre, radius: radius * ring.radius, startAngle: .radians(min(from, to)),
                                    endAngle: .radians(max(from, to)), clockwise: false)
                        context.stroke(path, with: .color(.white.opacity(ring.opacity)),
                                       style: StrokeStyle(lineWidth: width, lineCap: .round))
                    }
                }
            }
            core(design.core, in: &context, centre: centre, radius: radius * (compact ? 0.17 : 0.13))
        }
        .graphiteDisc(size: size)
    }

    private func core(_ kind: Int, in context: inout GraphicsContext, centre: CGPoint, radius: CGFloat) {
        let ink = GraphicsContext.Shading.color(.white)
        func polygon(_ corners: Int, turn: Double, scale: CGFloat) -> Path {
            var path = Path()
            for corner in 0..<corners {
                let angle = Double(corner) * 2 * .pi / Double(corners) + turn
                let point = CGPoint(x: centre.x + radius * scale * cos(angle), y: centre.y + radius * scale * sin(angle))
                if corner == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
            return path
        }
        let box = CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
        switch kind {
        case 0: context.fill(Path(ellipseIn: box), with: ink)
        case 1: context.stroke(Path(ellipseIn: box.insetBy(dx: radius * 0.2, dy: radius * 0.2)), with: ink, lineWidth: radius * 0.4)
        case 2: context.fill(polygon(4, turn: -.pi / 2, scale: 1.3), with: ink)
        case 3: context.fill(polygon(6, turn: .pi / 6, scale: 1.15), with: ink)
        default: context.fill(polygon(3, turn: -.pi / 2, scale: 1.35), with: ink)
        }
    }

    struct Arc: Equatable {
        /// Radians clockwise from the top, on the right half; the left half mirrors it.
        var start: Double
        var length: Double
    }

    struct Ring: Equatable {
        var radius: CGFloat
        var weight: CGFloat
        var opacity: Double
        var arcs: [Arc]
    }

    struct Design: Equatable {
        var rings: [Ring]
        var core: Int

        init(seed: UUID?) {
            var generator = SplitMix(seed: seed)
            func unit() -> Double { Double(generator.next() % 10_000) / 10_000 }
            rings = [(0.74, 0.085, 0.95, 1...2), (0.53, 0.065, 0.72, 1...3), (0.34, 0.05, 0.5, 1...2)].map { radius, weight, opacity, count in
                let arcs = (0..<Int.random(in: count, using: &generator)).map { _ in
                    // Arcs may cross the axis, where they meet their mirror and read as one.
                    Arc(start: unit() * .pi * 0.9, length: .pi * (0.18 + unit() * 0.5))
                }
                return Ring(radius: radius, weight: weight, opacity: opacity, arcs: arcs)
            }
            core = Int(generator.next() % 5)
        }
    }

    /// SplitMix64, seeded from the identity's bytes, so a mark is the same on every launch and Mac.
    struct SplitMix: RandomNumberGenerator {
        var state: UInt64

        init(seed: UUID?) {
            let bytes = seed.map { withUnsafeBytes(of: $0.uuid) { Array($0) } } ?? []
            state = bytes.reduce(0xCBF2_9CE4_8422_2325) { ($0 ^ UInt64($1)) &* 0x100_0000_01B3 }
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }
}

/// A symbol on the same graphite disc as the agents' marks, for groups and Investigations.
struct SymbolMark: View {
    let symbol: String
    let size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.4, weight: .medium))
            .foregroundStyle(.white.opacity(0.9))
            .graphiteDisc(size: size)
    }
}

extension View {
    /// A dark disc lit from above, the same in light and dark appearance, like a badge.
    func graphiteDisc(size: CGFloat) -> some View {
        frame(width: size, height: size)
            .background {
                Circle().fill(LinearGradient(colors: [Color(white: 0.26), Color(white: 0.08)], startPoint: .top, endPoint: .bottom))
            }
            .overlay {
                Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.3), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom),
                                      lineWidth: max(0.5, size / 64))
            }
            .accessibilityHidden(true)
    }
}

/// An agent's mark that opens its profile, as Noodle's bot pictures do: who it is, what it is doing,
/// and buttons to message it or edit it.
struct AgentProfileButton: View {
    let model: PionModel
    let agent: AgentRecord
    var size: CGFloat = 22
    var phase: AgentRuntimePhase?
    /// Inside a sheet, a message opens in a window of its own and editing is left to the sheet.
    var inSheet = false
    var edit: (() -> Void)?
    @Environment(\.openWindow) private var openWindow
    @State private var showsProfile = false
    @State private var pending: (() -> Void)?

    var body: some View {
        Button { showsProfile = true } label: {
            AgentMark(agent: agent, size: size, phase: phase).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Show \(agent.displayName)’s profile")
        .accessibilityLabel("Show profile for \(agent.displayName)")
        .popover(isPresented: $showsProfile, arrowEdge: .leading) {
            AgentProfile(model: model, agent: model.agent(agent.id) ?? agent,
                         message: model.directConversation(of: agent).map { direct in { finish {
                             if inSheet { openWindow(id: "conversation", value: direct.id) } else { model.selection = direct.id }
                         } } },
                         edit: inSheet ? nil : edit.map { edit in { finish(edit) } })
                .onDisappear {
                    // The popover detaches first, then the editor or conversation opens.
                    if let pending { self.pending = nil; DispatchQueue.main.async(execute: pending) }
                }
        }
    }

    private func finish(_ action: @escaping () -> Void) {
        pending = action
        showsProfile = false
    }
}

private struct AgentProfile: View {
    let model: PionModel
    let agent: AgentRecord
    let message: (() -> Void)?
    let edit: (() -> Void)?

    var body: some View {
        let phase = model.phase(of: agent)
        VStack(spacing: 14) {
            AgentMark(agent: agent, size: 84, phase: phase)
                .padding(.top, 6)
            VStack(spacing: 6) {
                Text(agent.displayName).font(.title2.weight(.semibold)).textSelection(.enabled)
                HStack(spacing: 6) {
                    Circle().fill(phase.color).frame(width: 6, height: 6)
                    Text(model.phaseDetail(of: agent) ?? phase.title).lineLimit(2)
                }
                .font(.callout)
                .foregroundStyle(phase == .failed ? Color.red : Color.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.quaternary, in: Capsule())
            }
            Text(agent.publicDescription?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "No description yet.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
            if message != nil || edit != nil {
                HStack(spacing: 8) {
                    if let message {
                        Button(action: message) { action("Message", "bubble.left") }.help("Direct Message")
                    }
                    if message != nil, edit != nil { Divider().frame(height: 32) }
                    if let edit {
                        Button(action: edit) { action("Edit", "pencil") }.help("Edit Agent")
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(width: 300)
    }

    private func action(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 18)).frame(height: 20)
            Text(title).font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
