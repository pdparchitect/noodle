import QuickLookUI
import SwiftUI
import SuperBotCore

struct AttachmentPreviewPopover: View {
    @Environment(\.dismiss) private var dismiss

    let attachment: ConversationAttachment
    let fileURL: URL
    let showInFinder: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: symbolName)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(attachment.originalFilename)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(ByteCountFormatter.string(
                        fromByteCount: attachment.byteCount,
                        countStyle: .file
                    ))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                Button("Show in Finder", systemImage: "folder") {
                    showInFinder()
                }
                .controlSize(.small)

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close Preview")
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 11)

            Divider()

            QuickLookPreview(fileURL: fileURL)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 620, height: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var symbolName: String {
        if attachment.mediaType.hasPrefix("image/") { return "photo.fill" }
        if attachment.mediaType == "application/pdf" { return "doc.richtext.fill" }
        if attachment.mediaType.hasPrefix("audio/") { return "waveform" }
        if attachment.mediaType.hasPrefix("video/") { return "film.fill" }
        return "doc.fill"
    }
}

private struct QuickLookPreview: NSViewRepresentable {
    let fileURL: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let preview = QLPreviewView(frame: .zero, style: .normal)!
        preview.autostarts = true
        return preview
    }

    func updateNSView(_ preview: QLPreviewView, context: Context) {
        preview.previewItem = fileURL as NSURL
        preview.refreshPreviewItem()
    }
}
