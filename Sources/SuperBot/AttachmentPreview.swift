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
    let isSelected: Bool
    let select: () -> Void
    let preview: () -> Void

    @State private var thumbnail: NSImage?
    @State private var thumbnailUnavailable = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if attachment.mediaType.hasPrefix("image/") {
                imagePreview
            } else {
                documentPreview
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .scaleEffect(isSelected ? 1.01 : 1)
        .shadow(
            color: isSelected ? Color.accentColor.opacity(0.55) : .clear,
            radius: 7
        )
        .animation(.easeOut(duration: 0.12), value: isSelected)
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onTapGesture(count: 2) {
            isFocused = true
            select()
            preview()
        }
        .onTapGesture {
            isFocused = true
            select()
        }
        .onKeyPress(.space) {
            select()
            preview()
            return .handled
        }
        .help("Select, then press Space or double-click to preview")
        .accessibilityLabel("Attachment \(attachment.originalFilename)")
        .accessibilityHint("Press Space or double-click to preview")
        .accessibilityAddTraits(.isButton)
        .task(id: fileURL) {
            await loadThumbnail()
        }
    }

    private var imagePreview: some View {
        ZStack {
            Color.black.opacity(0.12)

            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .transition(.opacity)
            } else {
                Image(systemName: attachment.previewSymbolName)
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(.secondary.opacity(thumbnailUnavailable ? 0.8 : 0.45))
            }
        }
        .frame(width: imagePreviewSize.width, height: imagePreviewSize.height)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .accessibilityHidden(true)
    }

    private var documentPreview: some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                Color.black.opacity(0.16)

                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                        .transition(.opacity)
                } else {
                    Image(systemName: attachment.previewSymbolName)
                        .font(.system(size: 38, weight: .light))
                        .foregroundStyle(.white.opacity(thumbnailUnavailable ? 0.72 : 0.42))
                }
            }
            .frame(width: 280, height: 165)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
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
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 2)
        }
        .frame(width: 280)
    }

    private var imagePreviewSize: CGSize {
        guard let thumbnail, thumbnail.size.width > 0, thumbnail.size.height > 0 else {
            return CGSize(width: 300, height: 200)
        }
        let scale = min(300 / thumbnail.size.width, 240 / thumbnail.size.height)
        return CGSize(
            width: max(120, thumbnail.size.width * scale),
            height: max(120, thumbnail.size.height * scale)
        )
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
