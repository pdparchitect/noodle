import HubLink
import SwiftUI

extension LinkRequestLine {
    var title: String {
        switch status {
        case .waiting: "Asking \(helperName)"
        case .answered: "\(helperName) answered"
        case .cancelled: "Cancelled asking \(helperName)"
        case .expired: "\(helperName) didn’t answer"
        case .withheld: "\(helperName) couldn’t help"
        }
    }

    var failed: Bool { status == .expired || status == .withheld }

    /// Someone a bot is shared with gets only how a request went, so there is nothing to open.
    var opens: Bool { text != nil }
}

/// Where a bot asked another for help: a slim line that opens in place to show the request and,
/// once the asking bot has it, the answer.
struct RequestLineRow: View {
    let line: LinkRequestLine
    @State private var isOpen = false

    var body: some View {
        Button { withAnimation(.snappy) { isOpen.toggle() } } label: {
            VStack(alignment: .leading, spacing: 8) {
                Label(line.title, systemImage: line.failed ? "exclamationmark.bubble" : "bubble.left.and.bubble.right")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(line.failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                if isOpen {
                    if let text = line.text { part("Request", text) }
                    if let answer = line.answer { part("Answer", answer) }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(!line.opens)
        .frame(maxWidth: .infinity)
    }

    private func part(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }
    }
}
