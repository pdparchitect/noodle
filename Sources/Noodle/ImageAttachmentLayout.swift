import SwiftUI
import NoodleCore

enum ChatImageLayout: String, CaseIterable, Identifiable {
    case wrap, vertical, stack

    static let defaultsKey = "chatImageLayout"
    static let defaultValue = Self.wrap
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wrap: return "Wrap"
        case .vertical: return "Vertical"
        case .stack: return "Stack"
        }
    }

    var explanation: String {
        switch self {
        case .wrap: return "Fit images side by side and wrap onto new rows as needed."
        case .vertical: return "Show images one below another, using the original chat layout."
        case .stack: return "Overlap images while keeping part of each picture visible. Click any picture to preview it."
        }
    }
}

/// Group only adjacent images within one message, preserving the position of
/// annotations, documents, voice recordings, and other attachments.
struct ImageAttachmentRun: Identifiable {
    let id: UUID
    let isImage: Bool
    var attachments: [ConversationAttachment]

    static func group(_ attachments: [ConversationAttachment],
                      isImage: (ConversationAttachment) -> Bool) -> [Self] {
        var runs: [Self] = []
        for attachment in attachments {
            let image = isImage(attachment)
            if image, runs.last?.isImage == true {
                runs[runs.count - 1].attachments.append(attachment)
            } else {
                runs.append(Self(id: attachment.id, isImage: image, attachments: [attachment]))
            }
        }
        return runs
    }
}

struct ImageAttachmentGroup<Content: View>: View {
    let attachments: [ConversationAttachment]
    let mode: ChatImageLayout
    let alignment: HorizontalAlignment
    @ViewBuilder let content: (ConversationAttachment) -> Content

    var body: some View {
        let layout = mode == .vertical
            ? AnyLayout(VStackLayout(alignment: alignment, spacing: 3))
            : AnyLayout(WrappingImageLayout(alignment: alignment,
                                           spacing: mode == .stack ? 12 : 8,
                                           overlapsImages: mode == .stack))
        layout {
            ForEach(attachments) { attachment in
                content(attachment)
                    .shadow(color: mode == .stack && attachments.count > 1 ? .black.opacity(0.25) : .clear,
                            radius: 3, y: 2)
            }
        }
    }
}

/// Uses each preview's natural size, so portrait screenshots share a row without
/// being cropped into square cells. Measurement and placement share one plan.
struct WrappingImageLayout: Layout {
    var alignment: HorizontalAlignment = .leading
    var spacing: CGFloat = 8
    var overlapsImages = false

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        plan(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let plan = plan(proposal: ProposedViewSize(width: bounds.width, height: nil), subviews: subviews)
        for (index, frame) in plan.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                                 anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    private func plan(proposal: ProposedViewSize, subviews: Subviews) -> ImageRowPlan {
        let width = overlapsImages ? min(220, proposal.width ?? 220) : proposal.width
        let sizes = subviews.map {
            $0.sizeThatFits(ProposedViewSize(width: width, height: nil))
        }
        return ImageRowPlan(sizes: sizes, availableWidth: proposal.width,
                            spacing: spacing, trailing: alignment == .trailing, overlapsImages: overlapsImages)
    }
}

struct ImageRowPlan {
    let size: CGSize
    let frames: [CGRect]

    init(sizes: [CGSize], availableWidth: CGFloat?, spacing: CGFloat, trailing: Bool, overlapsImages: Bool = false) {
        let limit = max(0, availableWidth ?? .infinity)
        var rows: [[CGRect]] = []
        var row: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for size in sizes {
            if !row.isEmpty, x + size.width > limit {
                rows.append(row)
                row = []
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            // A substantial side strip and a staggered top edge leave every
            // image recognizable and directly clickable. Start another row
            // when needed instead of squeezing the exposed strips away.
            let stagger = overlapsImages ? CGFloat(row.count) * 12 : 0
            row.append(CGRect(origin: CGPoint(x: x, y: y + stagger), size: size))
            x += overlapsImages ? min(72, size.width * 0.42) : size.width + spacing
            rowHeight = max(rowHeight, stagger + size.height)
        }
        if !row.isEmpty { rows.append(row) }
        let width = rows.flatMap { $0 }.map(\.maxX).max() ?? 0
        self.size = CGSize(width: width, height: sizes.isEmpty ? 0 : y + rowHeight)
        self.frames = rows.flatMap { row in
            let offset = trailing ? width - (row.map(\.maxX).max() ?? 0) : 0
            return row.map { $0.offsetBy(dx: offset, dy: 0) }
        }
    }
}
