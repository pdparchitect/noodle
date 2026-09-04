import QuickLookUI
import QuickLookThumbnailing
import SwiftUI
import SuperBotCore

extension ConversationAttachment {
    var previewSymbolName: String {
        if mediaType.hasPrefix("image/") { return "photo.fill" }
        if mediaType == "application/pdf" { return "doc.richtext.fill" }
        if mediaType.hasPrefix("audio/") { return "waveform" }
        if mediaType.hasPrefix("video/") { return "film.fill" }
        return "doc.fill"
    }
}

struct AttachmentInlinePreview: View {
    let attachment: ConversationAttachment
    let fileURL: URL

    @State private var thumbnail: NSImage?
    @State private var thumbnailUnavailable = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black.opacity(0.16)

                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .padding(5)
                        .transition(.opacity)
                } else {
                    Image(systemName: attachment.previewSymbolName)
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(.white.opacity(thumbnailUnavailable ? 0.72 : 0.42))
                }
            }
            .frame(height: 150)
            .accessibilityHidden(true)

            HStack(spacing: 8) {
                Image(systemName: attachment.previewSymbolName)
                    .font(.system(size: 16, weight: .medium))

                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.originalFilename)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                    Text(ByteCountFormatter.string(
                        fromByteCount: attachment.byteCount,
                        countStyle: .file
                    ))
                    .font(.system(size: 9.5))
                    .opacity(0.72)
                }

                Spacer(minLength: 3)

                Image(systemName: "eye.circle")
                    .font(.system(size: 13))
                    .opacity(0.75)
            }
            .foregroundStyle(.white)
            .padding(8)
        }
        .frame(width: 260)
        .background(.white.opacity(0.13))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.08))
        }
        .task(id: fileURL) {
            await loadThumbnail()
        }
    }

    @MainActor
    private func loadThumbnail() async {
        let key = fileURL as NSURL
        if let cached = AttachmentThumbnailCache.shared.object(forKey: key) {
            thumbnail = cached
            return
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: CGSize(width: 520, height: 300),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .all
        )

        do {
            let representation = try await QLThumbnailGenerator.shared
                .generateBestRepresentation(for: request)
            guard !Task.isCancelled else { return }
            let generated = representation.nsImage
            AttachmentThumbnailCache.shared.setObject(generated, forKey: key)
            withAnimation(.easeOut(duration: 0.15)) {
                thumbnail = generated
            }
        } catch {
            thumbnailUnavailable = true
        }
    }
}

@MainActor
private enum AttachmentThumbnailCache {
    static let shared = NSCache<NSURL, NSImage>()
}

struct AttachmentPreviewPopover: View {
    @Environment(\.dismiss) private var dismiss

    let attachment: ConversationAttachment
    let fileURL: URL
    let showInFinder: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: attachment.previewSymbolName)
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
