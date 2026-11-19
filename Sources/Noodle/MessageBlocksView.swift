import SwiftUI
import NoodleCore

/// A message's prose as its blocks: paragraphs, lists with their wrapped lines hanging under the text, and code set
/// apart, at the size each app reads at: Pion's reading column at 14 points, Noodle's bubbles smaller.
struct MessageBlocksView: View {
    let blocks: [MessageBlock]
    var message: ChatMessage?
    var size: CGFloat = 14
    var lineSpacing: CGFloat = 3.5
    /// The space between blocks; items in a list have half of it.
    var spacing: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .code(let text):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(text)
                            .font(.system(size: size - 2, design: .monospaced))
                            .padding(size * 0.85)
                    }
                    .background(Color.secondary.opacity(0.09), in: .rect(cornerRadius: 10, style: .continuous))
                case .text(let text):
                    prose(text)
                case .list(let items):
                    // Wrapped lines hang under the item's text, not its marker, with a little air between items.
                    // As wide as the longest number, so "10." fits and every item's text starts at the same place.
                    let widest = items.map(\.marker.count).max() ?? 1
                    let markerWidth = items.contains { $0.marker != "•" } ? size * (0.6 + CGFloat(widest) * 0.58) : size * 0.7
                    VStack(alignment: .leading, spacing: spacing / 2) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .firstTextBaseline, spacing: size * 0.43) {
                                Text(item.marker)
                                    .font(.system(size: size).monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                                    .frame(width: markerWidth, alignment: .trailing)
                                prose(item.text)
                            }
                        }
                    }
                    .padding(.leading, size * 0.15)
                }
            }
        }
    }

    private func prose(_ text: AttributedString) -> some View {
        Text(text)
            .font(.system(size: size))
            .lineSpacing(lineSpacing)
            .fixedSize(horizontal: false, vertical: true)
            .background { if let message { ConversationAnnotationText(message: message) } }
    }
}
