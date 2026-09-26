import QuickLookThumbnailing
import AppletBridge
import ComputerBridge
import BrowserBridge
import ImageIO
import SwiftUI
import NoodleCore
import UniformTypeIdentifiers

extension ConversationAttachment {
    var isBrowserLink: Bool { if case .browser = companion { return true } else { return false } }
    var isComputerLink: Bool { if case .computer = companion { return true } else { return false } }
    var isNoodletLink: Bool { if case .noodlet = companion { return true } else { return false } }

    /// Computers, browser tabs and noodlets open in a companion app instead of Quick Look.
    private var companionKey: String? {
        switch companion {
        case .browser(let id, let tab): "browser:\(id):\(tab?.uuidString ?? "")"
        case .computer(let id, _, _): "computer:\(id)"
        case .noodlet(let id): "noodlet:\(id)"
        case nil: nil
        }
    }

    var opensInCompanion: Bool { companionKey != nil }

    var companionKind: String {
        switch companion {
        case .browser: "Browser"
        case .computer: "Computer"
        default: "Noodlet"
        }
    }

    /// Noodlet previews live with the applet and are resolved on demand.
    var companionPreviewImage: Data? { card?.image }

    var companionSymbolName: String { isNoodletLink ? "square.grid.2x2" : previewSymbolName }

    var companionTitle: String { card?.title ?? (originalFilename as NSString).deletingPathExtension }

    /// One entry per computer, page or noodlet, keeping its most recent share.
    static func companions(newestFirst attachments: [ConversationAttachment]) -> [ConversationAttachment] {
        var seen = Set<String>()
        return attachments.filter { $0.companionKey.map { seen.insert($0).inserted } ?? false }
    }

    var previewSymbolName: String {
        if annotation != nil { return "text.bubble.fill" }
        if isBrowserLink { return card?.symbol ?? "globe" }
        if isComputerLink { return card?.symbol ?? "desktopcomputer" }
        if mediaType.hasPrefix("image/") { return "photo.fill" }
        if mediaType == "application/pdf" { return "doc.richtext.fill" }
        if mediaType.hasPrefix("audio/") { return "waveform" }
        if mediaType.hasPrefix("video/") { return "film.fill" }
        return "doc.fill"
    }
}

extension NoodleStore {
    func companions(in conversation: BotConversation) -> [ConversationAttachment] {
        ConversationAttachment.companions(newestFirst: messages(for: conversation).reversed().flatMap { attachments(for: $0) })
    }

    func openCompanion(_ attachment: ConversationAttachment) async throws {
        guard let link = attachment.companion, let url = attachment.url else { return }
        // On a Noodle Hub they run on the Hub's Mac, so their links open a live view instead.
        if hubMirrors.contains(where: { $0.owns(conversation: attachment.conversationID) }) {
            surfacePanels.open(HubSurfaceTarget(conversationID: attachment.conversationID, attachmentID: attachment.id,
                                                title: attachment.companionTitle), store: self)
            return
        }
        switch link {
        case .browser: try await browsers.open(url)
        case .computer: try await computers.open(url)
        case .noodlet: try await applets.openNoodlet(url)
        }
    }
}

/// Toolbar popover that reopens computers, browser pages and noodlets shared earlier in a conversation.
struct ConversationCompanionsMenu: View {
    @Environment(NoodleStore.self) private var store
    let conversation: BotConversation
    @State private var isPresented = false

    var body: some View {
        let companions = store.companions(in: conversation)
        if !companions.isEmpty {
            Button { isPresented.toggle() } label: {
                Label("Shared", systemImage: "square.stack")
            }
            .help("Shared Computers, Browsers and Noodlets")
            .popover(isPresented: $isPresented, arrowEdge: .bottom) {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(companions) { attachment in
                            CompanionRow(attachment: attachment) {
                                isPresented = false
                                Task { @MainActor in
                                    do { try await store.openCompanion(attachment) }
                                    catch { store.errorMessage = error.localizedDescription }
                                }
                            }
                        }
                    }
                    .padding(6)
                }
                .frame(width: 340, height: min(CGFloat(companions.count) * CompanionRow.height + 12, 460))
            }
        }
    }
}

private struct CompanionRow: View {
    static let height: CGFloat = 70
    @Environment(NoodleStore.self) private var store
    let attachment: ConversationAttachment
    let open: () -> Void
    @State private var noodletPreview: NSImage?
    @State private var noodletTitle: String?
    @State private var noodletUnavailable = false
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                preview
                    .frame(width: 84, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .lineLimit(2)
                        .truncationMode(.tail)
                    Text(noodletUnavailable ? "Noodlet unavailable" : attachment.companionKind)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: Self.height - 2)
            .contentShape(Rectangle())
            .background(isHovered ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(title)
        .task {
            guard let url = attachment.url, NoodletLink.id(in: url) != nil else { return }
            do {
                let preview = try await NoodletAttachmentCard.load(url, from: store.applets)
                noodletTitle = preview.title
                noodletPreview = preview.image
            } catch { noodletUnavailable = true }
        }
    }

    private var title: String { noodletTitle ?? attachment.companionTitle }

    @ViewBuilder private var preview: some View {
        if let image = attachment.companionPreviewImage.flatMap(NSImage.init(data:)) ?? noodletPreview {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            Image(systemName: noodletUnavailable ? "exclamationmark.link" : attachment.companionSymbolName)
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary.opacity(0.5))
        }
    }
}

struct AttachmentInlinePreview: View {
    let attachment: ConversationAttachment
    let fileURL: URL
    let shouldLoad: Bool
    let isSelected: Bool
    let select: () -> Void
    let preview: () -> Void
    private let imagePreviewSize: CGSize
    private let displaysAsImage: Bool

    @State private var thumbnail: NSImage?
    @State private var thumbnailUnavailable = false
    @FocusState private var isFocused: Bool

    init(
        attachment: ConversationAttachment,
        fileURL: URL,
        shouldLoad: Bool,
        isSelected: Bool,
        select: @escaping () -> Void,
        preview: @escaping () -> Void
    ) {
        self.attachment = attachment
        self.fileURL = fileURL
        self.shouldLoad = shouldLoad
        self.isSelected = isSelected
        self.select = select
        self.preview = preview
        displaysAsImage = attachment.mediaType.hasPrefix("image/") || AttachmentThumbnailCache.isImage(fileURL)
        imagePreviewSize = displaysAsImage
            ? AttachmentThumbnailCache.previewSize(for: fileURL)
            : CGSize(width: 300, height: 200)
    }

    var body: some View {
        if let voice = attachment.voice, attachment.mediaType.hasPrefix("audio/") {
            VoiceMessagePlayer(url: fileURL, voice: voice, shouldPlay: shouldLoad)
        } else {
            filePreview
        }
    }

    private var filePreview: some View {
        Group {
            if let note = attachment.annotation {
                annotationPreview(note)

            } else if let url = attachment.url, NoodletLink.id(in: url) != nil {
                NoodletAttachmentCard(url: url, shouldLoad: shouldLoad)
            } else if let card = attachment.card {
                linkCardPreview(card)
            } else if displaysAsImage {
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
        .onTapGesture {
            isFocused = true
            select()
            preview()
        }
        .onKeyPress(.space) {
            // Native preview children share our responder chain, but typing
            // in their editors must not activate the selected attachment card.
            guard !AttachmentPreviewController.containsPreviewWindow(NSApp.keyWindow),
                  !AttachmentPreviewController.containsPreviewWindow(NSApp.currentEvent?.window) else { return .ignored }
            select()
            preview()
            return .handled
        }
        .help(openHint)
        .accessibilityLabel("Attachment \(attachment.originalFilename)")
        .accessibilityHint(openHint)
        .accessibilityAddTraits(.isButton)
        .task(id: shouldLoad) {
            guard shouldLoad,
                  attachment.url.flatMap(NoodletLink.id) == nil,
                  attachment.annotation == nil || attachment.mediaType.hasPrefix("image/") else { return }
            await loadThumbnail()
        }
    }

    private var openHint: String {
        if attachment.isBrowserLink { return "Click or press Space to open in Noodle Browser" }
        if attachment.isComputerLink { return "Click or press Space to open in Noodle Computer" }
        if attachment.isNoodletLink { return "Click or press Space to open in \(AppletBuildIdentity.current.appName)" }
        return "Click or press Space to preview"
    }

    /// A browser tab or computer a bot shared: the picture taken then, and what it is.
    private func linkCardPreview(_ card: LinkCard) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                Color.black.opacity(0.16)
                if let thumbnail {
                    Image(nsImage: thumbnail).resizable().scaledToFit().padding(6).transition(.opacity)
                } else if let detail = card.detail, attachment.isComputerLink {
                    Text(detail).font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.8))
                        .lineLimit(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(10)
                } else {
                    Image(systemName: attachment.previewSymbolName)
                        .font(.system(size: 38, weight: .light)).foregroundStyle(.white.opacity(0.42))
                }
            }
            .frame(maxWidth: .infinity).frame(height: 165)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .accessibilityHidden(true)
            HStack(spacing: 8) {
                Image(systemName: attachment.previewSymbolName).font(.system(size: 16, weight: .medium))
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    Text(attachment.isBrowserLink ? (card.detail.flatMap { URL(string: $0)?.host } ?? "Browser") : "Computer")
                        .font(.system(size: 9.5)).opacity(0.72)
                }
                Spacer(minLength: 3)
            }
            .foregroundStyle(.primary).padding(.horizontal, 2)
        }
        .frame(idealWidth: 280, maxWidth: 280)
    }

    private func annotationPreview(_ note: AttachmentAnnotation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Annotation", systemImage: "text.bubble.fill")
                .font(.caption.weight(.semibold)).foregroundStyle(.orange)
            Text(note.sourceFilename).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if let quote = note.quote {
                Text(quote).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    .padding(.leading, 9)
                    .overlay(alignment: .leading) { Rectangle().fill(.orange.opacity(0.6)).frame(width: 2) }
            } else if note.region != nil {
                // Loading is driven by scroll visibility. Reserve the preview's
                // height before loading so it cannot move neighboring rows and
                // invalidate the lazy stack's placement as they become visible.
                ZStack {
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().scaledToFit()
                            .accessibilityLabel("Marked preview region")
                    } else {
                        Label("Marked preview region", systemImage: "viewfinder").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: attachment.mediaType.hasPrefix("image/") ? 190 : nil)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text(note.comment).font(.callout).lineLimit(4)
        }
        .padding(14).frame(idealWidth: 280, maxWidth: 280, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(.orange.opacity(0.2)))
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
        .aspectRatio(imagePreviewSize, contentMode: .fit)
        .frame(idealWidth: imagePreviewSize.width, maxWidth: imagePreviewSize.width)
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
            .frame(maxWidth: .infinity).frame(height: 165)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .accessibilityHidden(true)

            HStack(spacing: 8) {
                Image(systemName: attachment.previewSymbolName)
                    .font(.system(size: 16, weight: .medium))

                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.originalFilename)
                        .font(.system(size: 11.5, weight: .semibold))
                        .lineLimit(1)
                    Text(ByteCountFormatter.string(fromByteCount: attachment.byteCount, countStyle: .file))
                    .font(.system(size: 9.5))
                    .opacity(0.72)
                }

                Spacer(minLength: 3)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 2)
        }
        .frame(idealWidth: 280, maxWidth: 280)
    }

    @MainActor
    private func loadThumbnail() async {
        let key = fileURL as NSURL
        if let cached = AttachmentThumbnailCache.shared.object(forKey: key) {
            thumbnail = cached
            return
        }
        if let card = attachment.card {
            if let data = card.image,
               let source = CGImageSourceCreateWithData(data as CFData, nil),
               let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 1040,
                kCGImageSourceCreateThumbnailWithTransform: true
               ] as CFDictionary) {
                let result = NSImage(cgImage: image, size: .zero)
                AttachmentThumbnailCache.shared.setObject(result, forKey: key); thumbnail = result
            } else { thumbnailUnavailable = true }
            return
        }

        if displaysAsImage,
           let generated = await Task.detached(priority: .utility, operation: {
               AttachmentThumbnailCache.generateImageThumbnail(for: fileURL)
           }).value {
            guard !Task.isCancelled else { return }
            AttachmentThumbnailCache.shared.setObject(generated, forKey: key)
            withAnimation(.easeOut(duration: 0.15)) {
                thumbnail = generated
            }
            return
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: CGSize(width: 520, height: 300),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            // An icon returned before a provider is available is not a preview.
            // Keep the placeholder retryable instead of caching that icon.
            representationTypes: .thumbnail
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
enum AttachmentThumbnailCache {
    static let shared = NSCache<NSURL, NSImage>()
    private static var previewSizes: [URL: CGSize] = [:]

    static func isImage(_ url: URL) -> Bool {
        guard let source = imageSource(for: url),
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier) else { return false }
        return type.conforms(to: .image)
    }

    nonisolated static func generateImageThumbnail(for url: URL) -> NSImage? {
        guard let source = imageSource(for: url),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1_040,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }

    static func previewSize(for url: URL) -> CGSize {
        if let size = previewSizes[url] { return size }
        var size = CGSize(width: 300, height: 200)
        // Read dimensions from the header, without decoding pixels. The loading
        // placeholder and finished thumbnail then occupy exactly the same frame.
        if let source = imageSource(for: url),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
           let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
           width.doubleValue > 0, height.doubleValue > 0 {
            let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
            let rotated = (5...8).contains(orientation)
            let w = CGFloat(rotated ? height.doubleValue : width.doubleValue)
            let h = CGFloat(rotated ? width.doubleValue : height.doubleValue)
            let scale = min(300 / w, 240 / h)
            size = CGSize(width: max(120, w * scale), height: max(120, h * scale))
        }
        previewSizes[url] = size
        return size
    }

    nonisolated private static func imageSource(for url: URL) -> CGImageSource? {
        CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        )
    }
}
