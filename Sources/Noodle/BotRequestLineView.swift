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

/// Where a bot asked another for help: a slim line saying how it went. It never shows what was
/// asked or answered; the bot that asked tells the person what they need.
struct BotRequestLineView: View {
    @Environment(NoodleStore.self) private var store
    let line: BotRequestLine

    var body: some View {
        HStack {
            Spacer(minLength: 80)
            Label(line.title(helperName: helperName),
                  systemImage: line.failed ? "exclamationmark.bubble" : "bubble.left.and.bubble.right")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(line.failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
            Spacer(minLength: 80)
        }
    }

    /// The helper's current name, or the one it had when asked if it has gone since.
    private var helperName: String {
        line.helperID.flatMap { id in store.agents.first { $0.id == id } }?.displayName ?? line.helperName
    }
}
