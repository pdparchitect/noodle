import SwiftUI
import NoodleCore

/// Keeps a settings group compact while allowing rows with wrapped status or
/// error text to use their full height inside the scrollable area.
struct SettingsBotList<Row: View>: View {
    let agents: [AgentRecord]
    @ViewBuilder var row: (AgentRecord) -> Row

    var body: some View {
        SettingsBotListLayout {
            ViewThatFits(in: .vertical) {
                rows
                ScrollView {
                    rows
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .toggleStyle(.switch)
    }

    private var rows: some View {
        VStack(spacing: 10) {
            ForEach(agents) { agent in
                row(agent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if agent.id != agents.last?.id {
                    Divider()
                }
            }
        }
    }
}

/// Propose the height limit during measurement, including when the Settings
/// window asks for its ideal size. No later state update should resize the tab.
private struct SettingsBotListLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: 360))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}
