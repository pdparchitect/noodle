import NoodleCore
import NoodleRuntimeSettings
import HubWire
import SwiftUI

/// An agent's mark: a white chess piece on a graphite disc, the piece chosen from the agent's identity, so a rename
/// never changes it and the same agent shows the same piece everywhere.
struct AgentSigil: View {
    let seed: UUID?
    let size: CGFloat

    var body: some View {
        let piece = Self.piece(for: seed)
        // Small marks draw the piece larger and simpler, so it stays clear in a list.
        let compact = size < 30
        Canvas { context, canvas in
            let side = canvas.width * (compact ? 0.72 : 0.6)
            let box = CGRect(x: (canvas.width - side) / 2, y: (canvas.height - side) / 2, width: side, height: side)
            context.fill(piece.path(in: box, compact: compact), with: .color(.markInk), style: FillStyle(eoFill: true))
        }
        .graphiteDisc(size: size)
    }

    static func piece(for seed: UUID?) -> ChessPiece {
        var generator = SplitMix(seed: seed)
        return ChessPiece.allCases[Int(generator.next() % UInt64(ChessPiece.allCases.count))]
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

/// A group's mark: its agents' own pieces together on the graphite disc, as Noodle shows a group's members' pictures.
/// The first, the lead, stands in front; two more stand behind it, dimmer. With fewer members their pieces repeat, and
/// with none yet, as a new group starts, three pawns.
struct GroupSigil: View {
    /// The members, the one in front first.
    let members: [UUID]
    let size: CGFloat

    var body: some View {
        let pieces = members.isEmpty ? [ChessPiece.pawn] : members.prefix(3).map { AgentSigil.piece(for: $0) }
        // Small marks draw the pieces larger and simpler, so they stay clear in a list.
        let compact = size < 30
        Canvas { context, canvas in
            let width = canvas.width
            let back = width * (compact ? 0.46 : 0.4), front = width * (compact ? 0.62 : 0.52)
            // Behind, left and right, then the front piece over them.
            for (offset, side, piece) in [(-0.2, back, pieces[1 % pieces.count]), (0.2, back, pieces[2 % pieces.count]), (0, front, pieces[0])] {
                let isFront = side == front
                let box = CGRect(x: width / 2 + offset * width - side / 2, y: (canvas.height - side) / 2 + (isFront ? 0 : width * 0.02),
                                 width: side, height: side)
                let path = piece.path(in: box, compact: compact)
                // A dark outline parts the front piece from those behind it.
                if isFront {
                    context.stroke(path, with: .color(Color(nsColor: .windowBackgroundColor)),
                                   style: StrokeStyle(lineWidth: width * 0.05, lineCap: .round, lineJoin: .round))
                }
                context.fill(path, with: .color(.markInk.opacity(isFront ? 1 : 0.5)), style: FillStyle(eoFill: true))
            }
        }
        .graphiteDisc(size: size)
    }
}

/// The six pieces, drawn in the app icon's 1254-unit square in the style of its pawn: flat, geometric, one shape each.
enum ChessPiece: CaseIterable {
    case pawn, knight, bishop, rook, queen, king

    /// The outline in the icon's square; holes are cut by the even-odd rule.
    func outline(compact: Bool) -> Path {
        var path = Path()
        func roundRect(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat, _ r: CGFloat) {
            path.addRoundedRect(in: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0), cornerSize: CGSize(width: r, height: r))
        }
        func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) { path.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)) }
        /// A body rising from the base, `top` wide at `y`, flaring to the base.
        func body(top: CGFloat, y: CGFloat, foot: CGFloat = 185) {
            path.move(to: CGPoint(x: 627 - top, y: y))
            path.addLine(to: CGPoint(x: 627 + top, y: y))
            path.addCurve(to: CGPoint(x: 627 + foot, y: 872), control1: CGPoint(x: 627 + top + 2, y: y + 108),
                          control2: CGPoint(x: 627 + foot - 70, y: 790))
            path.addLine(to: CGPoint(x: 627 - foot, y: 872))
            path.addCurve(to: CGPoint(x: 627 - top, y: y), control1: CGPoint(x: 627 - foot + 70, y: 790),
                          control2: CGPoint(x: 627 - top - 2, y: y + 108))
            path.closeSubpath()
        }
        func polygon(_ points: [(CGFloat, CGFloat)]) {
            path.move(to: CGPoint(x: points[0].0, y: points[0].1))
            for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.0, y: point.1)) }
            path.closeSubpath()
        }
        // Every piece stands on the pawn's base.
        roundRect(366, 896, 888, 1018, 46)
        switch self {
        case .pawn:
            circle(627, 364, 128)
            roundRect(469, 506, 785, 574, 28)
            body(top: 74, y: 592)
        case .rook:
            polygon([(450, 300), (540, 300), (540, 370), (582, 370), (582, 300), (672, 300), (672, 370), (714, 370), (714, 300),
                     (804, 300), (804, 520), (450, 520)])
            roundRect(450, 540, 804, 600, 22)
            body(top: 120, y: 620)
        case .bishop:
            circle(627, 222, 40)
            path.move(to: CGPoint(x: 627, y: 270))
            path.addCurve(to: CGPoint(x: 714, y: 520), control1: CGPoint(x: 720, y: 340), control2: CGPoint(x: 742, y: 430))
            path.addLine(to: CGPoint(x: 540, y: 520))
            path.addCurve(to: CGPoint(x: 627, y: 270), control1: CGPoint(x: 512, y: 430), control2: CGPoint(x: 534, y: 340))
            path.closeSubpath()
            // The mitre's slit, cut out where it is big enough to see.
            if !compact { polygon([(668, 338), (690, 356), (612, 448), (590, 430)]) }
            roundRect(480, 540, 774, 600, 24)
            body(top: 70, y: 620)
        case .queen:
            polygon([(470, 540), (430, 320), (488, 440), (528, 280), (580, 420), (627, 262), (674, 420), (726, 280), (766, 440),
                      (824, 320), (784, 540)])
            // Balls on its points where they are big enough to see; small, the points alone read as a crown.
            if !compact { for (x, y) in [(430.0, 300.0), (528, 258), (627, 238), (726, 258), (824, 300)] { circle(x, y, 32) } }
            roundRect(470, 560, 784, 616, 24)
            body(top: 84, y: 636)
        case .king:
            // The cross, heavier when small so it does not blur away.
            let arm: CGFloat = compact ? 34 : 22
            roundRect(627 - arm, 180, 627 + arm, 372, 10)
            roundRect(545, 250 - arm, 709, 250 + arm, 10)
            path.move(to: CGPoint(x: 480, y: 540))
            path.addCurve(to: CGPoint(x: 627, y: 380), control1: CGPoint(x: 468, y: 440), control2: CGPoint(x: 510, y: 380))
            path.addCurve(to: CGPoint(x: 774, y: 540), control1: CGPoint(x: 744, y: 380), control2: CGPoint(x: 786, y: 440))
            path.closeSubpath()
            roundRect(470, 560, 784, 616, 24)
            body(top: 84, y: 636)
        case .knight:
            path.move(to: CGPoint(x: 452, y: 872))
            path.addCurve(to: CGPoint(x: 566, y: 646), control1: CGPoint(x: 456, y: 776), control2: CGPoint(x: 512, y: 700))
            path.addLine(to: CGPoint(x: 438, y: 612))
            path.addCurve(to: CGPoint(x: 392, y: 520), control1: CGPoint(x: 392, y: 600), control2: CGPoint(x: 370, y: 556))
            path.addLine(to: CGPoint(x: 530, y: 340))
            path.addLine(to: CGPoint(x: 566, y: 250))
            path.addLine(to: CGPoint(x: 618, y: 318))
            path.addCurve(to: CGPoint(x: 812, y: 600), control1: CGPoint(x: 736, y: 334), control2: CGPoint(x: 812, y: 450))
            path.addCurve(to: CGPoint(x: 800, y: 872), control1: CGPoint(x: 814, y: 720), control2: CGPoint(x: 806, y: 800))
            path.closeSubpath()
            circle(552, 432, 24)
        }
        return path
    }

    /// The outline fitted to `rect` and centred on its own bounds, so every piece sits in the middle of its disc.
    func path(in rect: CGRect, compact: Bool) -> Path {
        let shape = outline(compact: compact)
        let bounds = shape.boundingRect
        let scale = min(rect.width / bounds.width, rect.height / bounds.height)
        return shape.applying(CGAffineTransform(translationX: -bounds.midX, y: -bounds.midY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: rect.midX, y: rect.midY)))
    }
}

/// A symbol on the same graphite disc as the agents' marks, for groups and Investigations.
struct SymbolMark: View {
    let symbol: String
    let size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.4, weight: .medium))
            .foregroundStyle(Color.markInk)
            .graphiteDisc(size: size)
    }
}

extension View {
    /// A flat disc in a tint of the app's accent, the mark on it in a contrasting shade of the same accent, so marks
    /// carry the app's colour, blue for Pion and red for Rook, without reading as buttons.
    func graphiteDisc(size: CGFloat) -> some View {
        frame(width: size, height: size)
            .background {
                Circle().fill(Color.markDisc)
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
    /// From Settings, as in Noodle: a message opens in a window of its own, beside Settings.
    var opensMessageInWindow = false
    /// Shows the name beside the mark, clickable with it.
    var showsName = false
    var edit: (() -> Void)?
    /// In a group, as in Noodle: Reply addresses the agent in the message field.
    var reply: (() -> Void)?
    @Environment(\.openWindow) private var openWindow
    @State private var showsProfile = false
    @State private var pending: (() -> Void)?

    var body: some View {
        Button { showsProfile = true } label: {
            if showsName {
                HStack(spacing: 4) {
                    AgentMark(agent: agent, size: size, phase: phase)
                    Text(agent.displayName).font(.caption)
                }
                .contentShape(Rectangle())
            } else {
                AgentMark(agent: agent, size: size, phase: phase).contentShape(Circle())
            }
        }
        .buttonStyle(.plain)
        .help("Show \(agent.displayName)’s profile")
        .accessibilityLabel("Show profile for \(agent.displayName)")
        .popover(isPresented: $showsProfile, arrowEdge: .leading) {
            // Archived agents too, so the profile follows a change made in it.
            AgentProfile(model: model, agent: model.everyAgent.first { $0.id == agent.id } ?? agent,
                         reply: reply.map { reply in { finish(reply) } },
                         message: { finish {
                             guard let direct = model.directConversation(of: agent) else { return }
                             if inSheet || opensMessageInWindow { openWindow(id: "conversation", value: direct.id) } else { model.selection = direct.id }
                         } },
                         edit: inSheet ? nil : edit.map { edit in { finish(edit) } },
                         usage: { finish {
                             model.usage.agentFilter = agent.id
                             openWindow(id: UsageView.windowID)
                         } },
                         close: { showsProfile = false })
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

/// Noodle's profile card, with Pion's mark; under the name, the status the agent set, or else what it is doing.
private struct AgentProfile: View {
    let model: PionModel
    let agent: AgentRecord
    let reply: (() -> Void)?
    let message: () -> Void
    let edit: (() -> Void)?
    let usage: () -> Void
    let close: () -> Void
    @Environment(PionCalls.self) private var calls

    var body: some View {
        let phase = model.phase(of: agent)
        let heartbeat = TimeInterval(model.runtime.heartbeatConfiguration.intervalMinutes * 60)
        ProfileCard(picture: AnyView(AgentMark(agent: agent, size: 88, phase: phase)), name: agent.displayName,
                    status: AnyView(ProfileStatusBadge.bot(agent, heartbeat: heartbeat)
                        ?? ProfileStatusBadge(text: model.phaseDetail(of: agent) ?? phase.title, dot: phase.color,
                                              faded: true, isProblem: phase == .failed)),
                    description: ProfileCard.description(agent.publicDescription),
                    actions: actions, closeLabel: "Close agent profile", close: close)
    }

    private var actions: [ProfileCardAction] {
        var actions: [ProfileCardAction] = []
        if let reply { actions.append(.reply(reply)) }
        actions.append(.message(canOpen: model.directConversation(of: agent) != nil, message))
        if let callable {
            actions.append(.call(agent.displayName) {
                calls.startCall(in: callable)
                // The call's controls are in its conversation, so show it.
                message()
            })
        }
        if let edit { actions.append(.edit("Agent", edit)) }
        actions.append(.usage(usage))
        if agent.archivedAt == nil {
            actions.append(.suspend(isSuspended: agent.isSuspended(), noun: "Agent") { model.setSuspended(until: $0, agent: agent) })
        }
        return actions
    }

    /// The agent's own conversation, while it can take a call and is not already on one, as in Noodle.
    private var callable: BotConversation? {
        guard let direct = model.directConversation(of: agent), calls.canCallNow(in: direct),
              calls.voiceCalls.call?.conversationID != direct.id else { return nil }
        return direct
    }
}

/// A group's profile, as in Noodle: its picture, what it is for, who is in it, and Edit.
struct GroupProfileButton<Label: View>: View {
    let model: PionModel
    let group: BotConversation
    let edit: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var showsProfile = false
    @State private var pending: (() -> Void)?

    var body: some View {
        Button { showsProfile = true } label: { label().contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .help("Show \(group.displayName)’s profile")
            .accessibilityLabel("Show profile for \(group.displayName)")
            .popover(isPresented: $showsProfile, arrowEdge: .bottom) {
                ProfileCard(picture: AnyView(ConversationPicture(model: model, conversation: group, size: 88)),
                            name: model.title(of: group),
                            status: group.archivedAt != nil ? AnyView(ProfileStatusBadge(text: "Archived", faded: true)) : nil,
                            description: ProfileCard.description(group.publicDescription),
                            detail: model.members(of: group).map(\.displayName).joined(separator: ", "),
                            actions: [.button("Edit", systemImage: "pencil", help: "Edit Group") { pending = edit; showsProfile = false }],
                            closeLabel: "Close group profile") { showsProfile = false }
                    .onDisappear {
                        // The popover detaches first, then the editor opens.
                        if let pending { self.pending = nil; DispatchQueue.main.async(execute: pending) }
                    }
            }
    }
}

extension Color {
    /// The app's accent from its asset catalogue, as SwiftUI's `accentColor` is.
    private static let accent = NSColor(named: "AccentColor") ?? .controlAccentColor

    /// A mark's disc: a pale tint of the accent on a light window, a deep shade of it on a dark one.
    static let markDisc = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? (accent.blended(withFraction: 0.45, of: .black) ?? accent)
            : (accent.blended(withFraction: 0.8, of: .white) ?? accent)
    })

    /// A mark's piece or symbol: the accent itself on a light window, a light tint of it on a dark one, so the piece
    /// stands out from its disc.
    static let markInk = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? (accent.blended(withFraction: 0.75, of: .white) ?? .white)
            : accent
    })
}
