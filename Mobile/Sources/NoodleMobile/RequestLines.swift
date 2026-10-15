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
}

/// Where a bot asked another for help: a slim line saying how it went. It never shows what was
/// asked or answered; the bot that asked tells the person what they need.
struct RequestLineRow: View {
    let line: LinkRequestLine

    var body: some View {
        Label(line.title, systemImage: line.failed ? "exclamationmark.bubble" : "bubble.left.and.bubble.right")
            .font(.footnote.weight(.medium))
            .foregroundStyle(line.failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .frame(maxWidth: .infinity)
    }
}
