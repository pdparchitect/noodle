import NoodleCore
import SwiftUI

extension BotRequestLine {
    func title(helperName: String) -> String {
        switch status {
        case .waiting: "Asking \(helperName)"
        case .answered: "\(helperName) answered"
        case .cancelled: "Cancelled asking \(helperName)"
        case .expired: "\(helperName) didn’t answer"
        case .withheld: "\(helperName) couldn’t help"
        }
    }

    var failed: Bool { status == .expired || status == .withheld }
}

/// Where a bot asked another for help: a slim line that opens in place to show the request and,
/// once the asking bot has collected it, the answer.
struct BotRequestLineView: View {
    @Environment(NoodleStore.self) private var store
    let line: BotRequestLine
    @State private var isOpen = false

    var body: some View {
        HStack {
            Spacer(minLength: 80)
            Button { withAnimation(.snappy) { isOpen.toggle() } } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Label(line.title(helperName: helperName),
                          systemImage: line.failed ? "exclamationmark.bubble" : "bubble.left.and.bubble.right")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(line.failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    if isOpen {
                        if let text = line.text { part("Request", text) }
                        if let answer = line.answer { part("Answer", answer) }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                .contentShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .help(isOpen ? "Hide Request" : "Show Request")
            Spacer(minLength: 80)
        }
    }

    private func part(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 420, alignment: .leading)
    }

    /// The helper's current name, or the one it had when asked if it has gone since.
    private var helperName: String {
        line.helperID.flatMap { id in store.agents.first { $0.id == id } }?.displayName ?? line.helperName
    }
}
