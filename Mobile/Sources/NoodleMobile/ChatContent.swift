import CryptoKit
import HubLink
import ImageIO
@preconcurrency import LinkPresentation
import NoodlePatch
import NoodletRuntime
import PhotosUI
import QuickLook
import QuickLookThumbnailing
import SafariServices
import SwiftUI
import UniformTypeIdentifiers

extension EnvironmentValues {
    /// Opens a live link full screen, presented by the conversation rather than the card that was
    /// tapped; a noodlet where the person asked, if they did.
    @Entry var watchLive: @MainActor (LinkAttachment, NoodletManifest.Placement?) -> Void = { _, _ in }
}

/// One file in a message: a picture shown inline, anything else as a card. Tapping opens Quick Look,
/// which swipes through the other files of the same message, or a patch's review.
struct AttachmentView: View {
    let chats: HubChats
    let thread: HubThread
    let attachment: LinkAttachment
    /// Every attachment of the message this one belongs to.
    var group: [LinkAttachment] = []
    /// Sharing a row with others, so a picture takes less room.
    var compact = false
    @Environment(\.displayScale) private var displayScale
    @State private var url: URL?
    @State private var image: UIImage?
    @State private var failed = false
    /// Coming down to be opened, as a file shown from the Hub's preview is.
    @State private var opening = false
    @State private var previewing: URL?
    @State private var gallery: [URL] = []
    /// A live link with the card the Hub resolved for it, as a noodlet's name and picture.
    @State private var liveCard: LinkCardInfo?
    /// The file read as a patch, once it is on the phone and reads as one.
    @State private var patch: Patch?
    @Environment(\.watchLive) private var watchLive
    @Environment(\.reviewPatch) private var reviewPatch

    private var isImage: Bool { attachment.mediaType.hasPrefix("image/") }

    var body: some View {
        if attachment.isLive {
            live
        } else if let voice = attachment.voice {
            VoiceMessagePlayer(url: url, voice: voice)
                .task(id: attachment.id) { url = try? await chats.file(for: attachment, in: thread) }
        } else if let webLink = attachment.webLink {
            LinkPreviewCard(url: webLink, previews: chats.linkPreviews, conversationID: thread.conversationID)
        } else {
            file
        }
    }

    private var file: some View {
        Button(action: open) {
            if isImage { picture } else if let patch { PatchCard(patch: patch, filename: attachment.filename) } else { card }
        }
        .buttonStyle(.plain)
        .disabled(url == nil && image == nil)
        .overlay { if opening { ProgressView() } }
        .quickLookPreview($previewing, in: gallery)
        .contextMenu {
            if let url {
                ShareLink(item: url)
            } else {
                let chats = chats, thread = thread, attachment = attachment
                ShareLink(item: FileOnHub(filename: attachment.filename, mediaType: attachment.mediaType) {
                    try await chats.file(for: attachment, in: thread)
                }, preview: SharePreview(attachment.filename))
            }
            // As on the Mac: a picture in the conversation can become its backdrop.
            if isImage {
                Button("Use as Background", systemImage: "photo.on.rectangle") {
                    Task { try? await chats.setBackground(photo: Data(contentsOf: chats.file(for: attachment, in: thread)), for: thread) }
                }
            }
        }
        .task(id: attachment.id) { await load() }
    }

    /// The card as the Hub resolved it this time, else as this phone kept it, else as shared.
    private var shownCard: LinkCardInfo? { liveCard ?? chats.keptCard(for: attachment) ?? attachment.card }

    /// A browser tab, computer or noodlet a bot shared: its last picture, opening live on the Hub's Mac.
    private var live: some View {
        Button { watchLive(attachment, nil) } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    Color(.secondarySystemBackground)
                    if let data = shownCard?.image, let image = DecodedImages.picture(data) {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else if attachment.liveKind == .computer, let terminal = shownCard?.detail {
                        // A computer shared as its terminal shows its latest lines, as on the Mac.
                        Text(terminal).font(.system(size: 7, design: .monospaced)).foregroundStyle(.white.opacity(0.8))
                            .lineLimit(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(8)
                            .background(.black)
                    } else {
                        Image(systemName: attachment.card?.symbol ?? "rectangle.on.rectangle").font(.largeTitle).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 240, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text(shownCard?.title ?? attachment.liveTitle)
                    .font(.subheadline.weight(.medium)).lineLimit(1)
            }
            .padding(8)
            .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens it live")
        .contextMenu {
            if attachment.liveKind == .noodlet {
                Button("Open on \(UIDevice.current.model)", systemImage: "iphone") { watchLive(attachment, .device) }
                Button("Open on Hub", systemImage: "play.display") { watchLive(attachment, .hub) }
            }
        }
        .task(id: attachment.id) {
            // Cards come without their pictures, a noodlet's without its name; each is fetched as its card comes into view.
            guard attachment.card?.image == nil else { return }
            liveCard = await chats.sharedAttachment(attachment, in: thread).card
        }
    }

    /// The most room a picture takes in the conversation.
    private static let pictureBounds = CGSize(width: 240, height: 320)
    /// Small enough for two to share a row.
    private static let compactBounds = CGSize(width: 144, height: 192)
    /// The least, so a long strip stays big enough to tap.
    private static let pictureMinimum: CGFloat = 44

    /// The room a picture of this size takes, known before it loads so the conversation does not shift.
    /// Nil without a size: a placeholder stands in and the picture takes its own room once loaded.
    static func pictureFrame(for size: LinkPixelSize?, compact: Bool = false) -> CGSize? {
        guard let size else { return nil }
        let bounds = compact ? compactBounds : pictureBounds
        let scale = min(bounds.width / CGFloat(size.width), bounds.height / CGFloat(size.height))
        return CGSize(width: max(pictureMinimum, (CGFloat(size.width) * scale).rounded()),
                      height: max(pictureMinimum, (CGFloat(size.height) * scale).rounded()))
    }

    @ViewBuilder private var picture: some View {
        let frame = Self.pictureFrame(for: attachment.pixelSize, compact: compact)
        let bounds = compact ? Self.compactBounds : Self.pictureBounds
        if let image = shownImage {
            if let frame {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: frame.width, height: frame.height)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: bounds.width, maxHeight: bounds.height)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
                .frame(width: frame?.width ?? bounds.width, height: frame?.height ?? bounds.width * 2 / 3)
                .overlay { status }
        }
    }

    private var card: some View {
        HStack(spacing: 10) {
            Group {
                if let image = shownImage {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: failed ? "exclamationmark.triangle" : Self.symbol(for: attachment.mediaType))
                        .font(.title2).foregroundStyle(.secondary)
                }
            }
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.filename).font(.subheadline.weight(.medium)).lineLimit(2)
                Text(Int64(attachment.byteCount), format: .byteCount(style: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: 260)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder private var status: some View {
        if failed {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
        } else {
            ProgressView()
        }
    }

    /// A file shown from the Hub's preview comes down first, and the rest of its message alongside;
    /// files still downloading are left out rather than holding the preview back.
    private func open() {
        Task {
            if url == nil {
                let others = LinkAttachment.previewGallery(opening: attachment, among: group).filter { $0.id != attachment.id }
                for other in others where chats.downloadedFile(for: other) == nil {
                    Task { _ = try? await chats.file(for: other, in: thread) }
                }
                opening = true
                url = try? await chats.file(for: attachment, in: thread)
                opening = false
            }
            guard let url else { return }
            if let patch, let reviewPatch {
                reviewPatch(PatchReviewRequest(attachment: attachment, patch: patch, file: url))
                return
            }
            gallery = LinkAttachment.previewGallery(opening: attachment, among: group).compactMap {
                $0.id == attachment.id ? url : chats.downloadedFile(for: $0)
            }
            previewing = url
        }
    }

    /// Pixels decoded for a picture's bubble, or for a file card's thumbnail.
    private var shownPixels: Int { isImage ? 720 : 132 }

    /// The picture as decoded the last time this bubble was drawn, so it shows at once when it comes back.
    private var shownImage: UIImage? {
        image ?? (chats.downloadedFile(for: attachment) ?? chats.keptPreview(for: attachment))
            .flatMap { DecodedImages.shown($0, at: shownPixels) }
    }

    /// A file already on the phone shows from itself; a picture, video or PDF from the Hub's preview,
    /// coming down only when opened; anything else comes down to be shown.
    private func load() async {
        do {
            if let file = chats.downloadedFile(for: attachment) {
                url = file
                if await readPatch(file) { return }
                image = await shown(file, isPreview: false)
            } else if attachment.hasHubPreview, let preview = try await chats.preview(of: attachment, in: thread) {
                image = await shown(preview, isPreview: true)
            } else {
                let file = try await chats.file(for: attachment, in: thread)
                url = file
                if await readPatch(file) { return }
                image = await shown(file, isPreview: false)
            }
        } catch {
            failed = true
        }
    }

    /// A patch shows what it changes on its card instead of a thumbnail; true when the file reads as one.
    private func readPatch(_ file: URL) async -> Bool {
        guard attachment.isPatchFile else { return false }
        patch = await PatchCache.patch(at: file)
        return patch != nil
    }

    private func shown(_ file: URL, isPreview: Bool) async -> UIImage? {
        if let shown = DecodedImages.shown(file, at: shownPixels) { return shown }
        guard isImage || isPreview else { return await thumbnail(of: file) }
        let pixels = shownPixels
        return await Task.detached(priority: .userInitiated) { DecodedImages.downsampled(file, to: pixels) }.value
    }

    private func thumbnail(of file: URL) async -> UIImage? {
        let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: 88, height: 88), scale: displayScale,
                                                   representationTypes: .thumbnail)
        guard let image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage else { return nil }
        DecodedImages.keep(image, of: file, at: shownPixels)
        return image
    }

    static func symbol(for mediaType: String) -> String {
        if mediaType.hasPrefix("image/") { return "photo" }
        if mediaType.hasPrefix("video/") { return "film" }
        if mediaType.hasPrefix("audio/") { return "waveform" }
        if mediaType == "application/pdf" { return "doc.richtext" }
        if mediaType.hasPrefix("text/") { return "doc.text" }
        return "doc"
    }
}

/// How the files of a message sit together, as on the Mac.
enum AttachmentLayout: String, CaseIterable, Identifiable {
    case wrap, vertical, stack

    static let key = "chatAttachmentLayout"
    static let standard = Self.vertical
    var id: String { rawValue }
    var name: String { rawValue.capitalized }

    var explanation: String {
        switch self {
        case .wrap: "Files sit side by side and wrap onto new rows."
        case .vertical: "Files sit one below another."
        case .stack: "Files overlap, with part of each one showing."
        }
    }
}

extension MessageTextLayout {
    static let key = "messageTextLayout"
    static let standard = Self.together
    var name: String { rawValue.capitalized }

    var explanation: String {
        switch self {
        case .together: "Each message sits in one bubble."
        case .paragraphs: "Every blank line starts a new bubble."
        case .chunks: "Paragraphs group into short bubbles, keeping a line that ends in a colon with what follows."
        }
    }
}

/// A message's files, as on the Mac: Stack overlaps only files that swipe together; the rest wrap above them, whole.
struct MessageAttachments<Content: View>: View {
    let attachments: [LinkAttachment]
    let mode: AttachmentLayout
    let trailing: Bool
    /// An attachment's view, told whether it shares a row with others.
    @ViewBuilder let content: (LinkAttachment, Bool) -> Content

    var body: some View {
        let parts = mode == .stack ? LinkAttachment.arranged(attachments) : (alone: [], together: attachments)
        VStack(alignment: trailing ? .trailing : .leading, spacing: 8) {
            if !parts.alone.isEmpty { rows(parts.alone, mode: .wrap) }
            if !parts.together.isEmpty { rows(parts.together, mode: mode) }
        }
    }

    private func rows(_ attachments: [LinkAttachment], mode: AttachmentLayout) -> some View {
        let together = mode != .vertical && attachments.count > 1
        return AttachmentRows(mode: mode, trailing: trailing) {
            ForEach(attachments) { attachment in
                content(attachment, together)
                    .shadow(color: mode == .stack && together ? .black.opacity(0.3) : .clear, radius: 3, y: 2)
            }
        }
    }
}

/// Places a message's files by `mode`, each at its own size. Measuring and placing share one plan.
struct AttachmentRows: Layout {
    let mode: AttachmentLayout
    let trailing: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        plan(proposal.width, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, plan(bounds.width, subviews).frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func plan(_ width: CGFloat?, _ subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        Self.plan(sizes: subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) },
                  width: width, mode: mode, trailing: trailing)
    }

    /// Rows filled left to right, the Mac's plan: a stack overlaps each file, leaving a strip of the one below
    /// and dropping its top a little, and starts another row rather than hiding the strips.
    static func plan(sizes: [CGSize], width: CGFloat?, mode: AttachmentLayout, trailing: Bool) -> (size: CGSize, frames: [CGRect]) {
        let limit = mode == .vertical ? 0 : max(0, width ?? .infinity)
        let spacing: CGFloat = switch mode { case .vertical: 4; case .wrap: 8; case .stack: 12 }
        var rows: [[CGRect]] = []
        var row: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for size in sizes {
            if !row.isEmpty, x + size.width > limit {
                rows.append(row)
                row = []
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            let stagger = mode == .stack ? CGFloat(row.count) * 12 : 0
            row.append(CGRect(origin: CGPoint(x: x, y: y + stagger), size: size))
            x += mode == .stack ? min(72, size.width * 0.42) : size.width + spacing
            rowHeight = max(rowHeight, stagger + size.height)
        }
        if !row.isEmpty { rows.append(row) }
        let widest = rows.joined().map(\.maxX).max() ?? 0
        let frames = rows.flatMap { row in
            let shift = trailing ? widest - (row.map(\.maxX).max() ?? 0) : 0
            return row.map { $0.offsetBy(dx: shift, dy: 0) }
        }
        return (CGSize(width: widest, height: sizes.isEmpty ? 0 : y + rowHeight), frames)
    }
}

/// Web links open in a preview first, whose Safari button continues in the browser, as on the Mac.
enum WebLinkPreview {
    static let key = "webLinksPreview"

    /// The link to preview, or nil when it goes straight to the system.
    static func previewed(_ url: URL, enabled: Bool) -> URL? {
        guard enabled, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false else { return nil }
        return url
    }
}

/// A web link being previewed.
struct PreviewedLink: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Safari inside the app, with its own button to open the page in Safari.
struct WebPreview: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// The preview card for the first public web link in a message, as on the Mac.
enum LinkPreview {
    static func firstURL(in text: String) -> URL? {
        let markdown = (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))?
            .runs.compactMap(\.link) ?? []
        let detected = (try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue))?
            .matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap(\.url) ?? []
        return (markdown + detected).first(where: isPublicWeb)
    }

    /// http or https to a named host, never this network: previews fetch the page from the phone.
    static func isPublicWeb(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host()?.lowercased(), host.contains("."), !host.contains(":"),
              !host.hasSuffix(".local"), !host.hasSuffix(".localhost") else { return false }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return true }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (169, 254), (192, 168), (0, _): return false
        case (172, let second): return !(16...31).contains(second)
        default: return true
        }
    }
}

/// What a link's card shows.
struct LinkCard: Codable, Equatable {
    var title: String
    var site: String
    var image: Data?

    /// The card of a page that gave nothing away: its site alone.
    init(site url: URL) {
        let host = url.host() ?? url.absoluteString
        let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        self.init(title: site, site: site, image: nil)
    }

    init(title: String, site: String, image: Data?) {
        self.title = title
        self.site = site
        self.image = image
    }
}

/// Link cards, kept on this phone with their conversation for a week, then fetched again so they do not
/// go stale. A page that gives nothing away gets a card naming its site and is tried again next launch.
@MainActor final class LinkPreviews {
    typealias Fetch = @MainActor (URL) async -> LinkCard?

    static let lifetime: TimeInterval = 7 * 86_400

    private struct Saved: Codable {
        var card: LinkCard
        var savedAt: Date
    }

    private let folder: URL
    private let fetch: Fetch
    private let now: () -> Date
    private var cards: [URL: Saved] = [:]
    /// Fetches under way, by page, so a page linked in two conversations at once is fetched once.
    private var pending: [URL: Task<LinkCard?, Never>] = [:]

    init(folder: URL, fetch: @escaping Fetch = LinkPreviews.fetched, now: @escaping () -> Date = Date.init) {
        self.folder = folder
        self.fetch = fetch
        self.now = now
    }

    func card(for url: URL, in conversationID: UUID) async -> LinkCard {
        let file = self.file(for: url, in: conversationID)
        if let saved = cards[file] ?? Self.saved(at: file), isFresh(saved) {
            cards[file] = saved
            return saved.card
        }
        // The same page linked in another conversation: its card is copied, so each conversation's
        // cards still go with it.
        if let saved = savedElsewhere(file), isFresh(saved) {
            save(saved, to: file)
            return saved.card
        }
        let task = pending[url] ?? Task { await fetch(url) }
        pending[url] = task
        let fetched = await task.value
        pending[url] = nil
        let saved = Saved(card: fetched ?? LinkCard(site: url), savedAt: now())
        if fetched != nil { save(saved, to: file) } else { cards[file] = saved }
        return saved.card
    }

    private func save(_ saved: Saved, to file: URL) {
        cards[file] = saved
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(saved).write(to: file, options: .atomic)
    }

    /// The same page's card kept with another conversation.
    private func savedElsewhere(_ file: URL) -> Saved? {
        let name = file.lastPathComponent
        if let known = cards.first(where: { $0.key.lastPathComponent == name && isFresh($0.value) }) { return known.value }
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .lazy.compactMap { Self.saved(at: $0.appendingPathComponent(name)) }.first(where: isFresh)
    }

    func forget(_ conversationID: UUID) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(conversationID.uuidString, isDirectory: true))
        cards = cards.filter { $0.key.deletingLastPathComponent().lastPathComponent != conversationID.uuidString }
    }

    /// Forgets the cards of every conversation but these, and the cards older than a week.
    func keep(only conversationIDs: Set<UUID>) {
        let names = Set(conversationIDs.map(\.uuidString))
        for folder in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            guard names.contains(folder.lastPathComponent) else {
                if let id = UUID(uuidString: folder.lastPathComponent) { forget(id) }
                continue
            }
            for file in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where !(Self.saved(at: file).map(isFresh) ?? false) {
                try? FileManager.default.removeItem(at: file)
                cards[file] = nil
            }
        }
    }

    private func isFresh(_ saved: Saved) -> Bool { now().timeIntervalSince(saved.savedAt) < Self.lifetime }

    private static func saved(at file: URL) -> Saved? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
    }

    private func file(for url: URL, in conversationID: UUID) -> URL {
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent(conversationID.uuidString, isDirectory: true).appendingPathComponent(name + ".json")
    }

    /// The page's title and picture, fetched from the phone. The picture is kept small.
    static func fetched(_ url: URL) async -> LinkCard? {
        let provider = LPMetadataProvider()
        provider.timeout = 10
        guard let metadata = try? await provider.startFetchingMetadata(for: url) else { return nil }
        let image: Data? = await withCheckedContinuation { continuation in
            guard let item = metadata.imageProvider, item.canLoadObject(ofClass: UIImage.self) else { return continuation.resume(returning: nil) }
            item.loadObject(ofClass: UIImage.self) { object, _ in
                guard let image = object as? UIImage, image.size.width > 0 else { return continuation.resume(returning: nil) }
                let width = min(image.size.width * image.scale, 560)
                let size = CGSize(width: width, height: (width * image.size.height / image.size.width).rounded())
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                continuation.resume(returning: UIGraphicsImageRenderer(size: size, format: format)
                    .jpegData(withCompressionQuality: 0.8) { _ in image.draw(in: CGRect(origin: .zero, size: size)) })
            }
        }
        let site = LinkCard(site: url).site
        return LinkCard(title: metadata.title.flatMap { $0.isEmpty ? nil : $0 } ?? site, site: site, image: image)
    }
}

/// The card for the first public web link in a message, drawn as on the Mac.
struct LinkPreviewCard: View {
    let url: URL
    let previews: LinkPreviews
    let conversationID: UUID
    @State private var card: LinkCard?
    @Environment(\.openURL) private var openURL

    var body: some View {
        // Tapped here rather than in the card, so the link opens as the conversation's other links do.
        Button { openURL(url) } label: {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Color.black.opacity(0.28)
                    if let data = card?.image, let image = DecodedImages.picture(data) {
                        Image(uiImage: image).resizable().scaledToFill()
                            .frame(width: 280, height: 158, alignment: .top)
                    } else if card == nil {
                        ProgressView()
                    } else {
                        Image(systemName: "link").font(.system(size: 26, weight: .light)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 280, height: 158)
                .clipped()
                VStack(alignment: .leading, spacing: 3) {
                    Text(card?.title ?? LinkCard(site: url).title)
                        .font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    Text(card?.site ?? LinkCard(site: url).site).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(width: 280, alignment: .leading)
            }
            .background(Color(.tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .task(id: url) { card = await previews.card(for: url, in: conversationID) }
    }
}

/// A file picked for the next message, with a button to take it back out.
struct PendingFileChip: View {
    let file: OutgoingFile
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if file.mediaType.hasPrefix("image/"), let image = DecodedImages.downsampled(file.url, to: 96) {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: AttachmentView.symbol(for: file.mediaType)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(file.filename).font(.caption).lineLimit(1).frame(maxWidth: 120, alignment: .leading)
            Button(action: remove) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(file.filename)")
        }
        .padding(6)
        .background(Color(.secondarySystemBackground), in: Capsule())
    }
}

/// The camera, returning one photo.
struct CameraPicker: UIViewControllerRepresentable {
    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }
    /// Lets the person move and scale the photo into a square before it is used.
    var cropsSquare = false
    let taken: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.allowsEditing = cropsSquare
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(taken: taken) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let taken: (UIImage) -> Void

        init(taken: @escaping (UIImage) -> Void) { self.taken = taken }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = (info[.editedImage] ?? info[.originalImage]) as? UIImage { taken(image) }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { picker.dismiss(animated: true) }
    }
}

/// The message field. A text view rather than a SwiftUI field, so pasting a copied image attaches it,
/// as in Messages. It grows to six lines, then scrolls.
struct ComposerField: UIViewRepresentable {
    @Binding var text: String
    /// Where the caret is, in UTF-16 units, as `NSRange` counts.
    @Binding var caret: Int
    let placeholder: String
    let pasted: (UIImage) -> Void
    @Environment(\.isEnabled) private var isEnabled

    func makeUIView(context: Context) -> PastingTextView {
        let view = PastingTextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.placeholder.text = placeholder
        return view
    }

    func updateUIView(_ view: PastingTextView, context: Context) {
        if view.text != text {
            view.text = text
            view.selectedRange = NSRange(location: min(caret, text.utf16.count), length: 0)
        }
        view.placeholder.text = placeholder
        view.placeholder.isHidden = !text.isEmpty
        view.isEditable = isEnabled
        view.pasted = pasted
        context.coordinator.text = $text
        context.coordinator.caret = $caret
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PastingTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 240
        let fitting = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        let limit = ceil((uiView.font?.lineHeight ?? 22) * 6)
        uiView.isScrollEnabled = fitting > limit
        return CGSize(width: width, height: min(fitting, limit))
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, caret: $caret) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>
        var caret: Binding<Int>

        init(text: Binding<String>, caret: Binding<Int>) {
            self.text = text
            self.caret = caret
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
            (textView as? PastingTextView)?.placeholder.isHidden = !textView.text.isEmpty
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            // A selection is not a place to complete a name.
            caret.wrappedValue = textView.selectedRange.length == 0 ? textView.selectedRange.location : -1
        }
    }
}

/// Offers Paste for copied images too, and hands them over instead of inserting them.
/// A paste the person chooses from the edit menu is always allowed; reading the clipboard
/// from code is not.
final class PastingTextView: UITextView {
    var pasted: ((UIImage) -> Void)?
    let placeholder = UILabel()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholder.font = .preferredFont(forTextStyle: .body)
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = .placeholderText
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholder.topAnchor.constraint(equalTo: topAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("Not used from a storyboard.") }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages { return true }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if UIPasteboard.general.hasImages, let images = UIPasteboard.general.images, !images.isEmpty {
            images.forEach { pasted?($0) }
        } else {
            super.paste(sender)
        }
    }
}

/// Typing @ and part of a bot's name offers the bot, as on the Mac. Choosing one writes its plain name.
struct MentionCompletion: Equatable {
    let range: NSRange
    let query: String

    static func request(in text: String, caret: Int) -> Self? {
        let utf16 = text.utf16
        guard caret >= 0, caret <= utf16.count,
              let caretIndex = utf16.index(utf16.startIndex, offsetBy: caret, limitedBy: utf16.endIndex)
                .flatMap({ $0.samePosition(in: text) }) else { return nil }
        let prefix = text[..<caretIndex]
        guard let at = prefix.lastIndex(of: "@") else { return nil }
        if at != text.startIndex {
            let preceding = text[text.index(before: at)]
            guard preceding.isWhitespace || "([{,:".contains(preceding) else { return nil }
        }
        let query = String(text[text.index(after: at)..<caretIndex])
        guard query.count <= 64, !query.contains(where: \.isNewline),
              query.allSatisfy({ $0.isLetter || $0.isNumber || " '-_.".contains($0) }) else { return nil }
        var end = caretIndex
        while end < text.endIndex, text[end].isLetter || text[end].isNumber || "-_".contains(text[end]) {
            end = text.index(after: end)
        }
        return Self(range: NSRange(at..<end, in: text), query: query)
    }

    /// Bots whose name contains what was typed; `preferred` first, then by name.
    func matches(_ bots: [LinkBot], preferred: UUID?) -> [LinkBot] {
        bots.filter { query.isEmpty || $0.draft.name.localizedCaseInsensitiveContains(query) }
            .sorted {
                let left = $0.id == preferred, right = $1.id == preferred
                if left != right { return left }
                return $0.draft.name.localizedStandardCompare($1.draft.name) == .orderedAscending
            }
    }

    func replacing(with name: String, in text: String) -> String {
        guard let range = Range(range, in: text) else { return text }
        return text.replacingCharacters(in: range, with: name + (range.upperBound == text.endIndex ? " " : ""))
    }
}

/// A bot's picture as Noodle on the Mac stores one: fitted within 512 pixels, upright, as JPEG.
enum BotPicture {
    static func prepare(_ data: Data) throws -> Data {
        guard data.count <= 50 * 1024 * 1024 else { throw LinkError("Choose an image smaller than 50 MB.") }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 512,
                kCGImageSourceCreateThumbnailWithTransform: true,
              ] as CFDictionary),
              let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.86) else {
            throw LinkError("That image could not be used.")
        }
        return jpeg
    }
}

/// The things shared in a conversation, with enough of each to choose it before opening live.
struct SharedAttachments: View {
    let chats: HubChats
    let thread: HubThread
    let attachments: [LinkAttachment]
    let open: (LinkAttachment) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(attachments) { attachment in
                SharedAttachmentRow(chats: chats, thread: thread, attachment: attachment, open: open)
            }
            .navigationTitle("Shared")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

private struct SharedAttachmentRow: View {
    let chats: HubChats
    let thread: HubThread
    let attachment: LinkAttachment
    let open: (LinkAttachment) -> Void
    @State private var resolved: LinkAttachment?

    /// Resolved this time, else with the card this phone kept, so its picture shows at once.
    private var shown: LinkAttachment {
        if let resolved { return resolved }
        var shown = attachment
        if let kept = chats.keptCard(for: attachment) { shown.card = kept }
        return shown
    }

    var body: some View {
        Button { open(shown) } label: {
            HStack(spacing: 12) {
                Group {
                    if let data = shown.card?.image, let image = DecodedImages.picture(data) {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else {
                        Image(systemName: shown.liveSymbol).font(.title2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 96, height: 64)
                .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(shown.liveTitle).foregroundStyle(.primary).lineLimit(2)
                    Text(shown.liveKindName).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(.plain)
        .task(id: attachment.id) { resolved = await chats.sharedAttachment(attachment, in: thread) }
    }
}

/// A conversation's file shared before it is on the phone: it comes down from the Hub as it is shared.
struct FileOnHub: Transferable {
    let filename: String
    let mediaType: String
    let download: @Sendable () async throws -> URL

    private var type: UTType { UTType(mimeType: mediaType) ?? .data }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .image) { SentTransferredFile(try await $0.download()) }
            .exportingCondition { $0.type.conforms(to: .image) }
            .suggestedFileName { $0.filename }
        FileRepresentation(exportedContentType: .movie) { SentTransferredFile(try await $0.download()) }
            .exportingCondition { $0.type.conforms(to: .movie) }
            .suggestedFileName { $0.filename }
        FileRepresentation(exportedContentType: .pdf) { SentTransferredFile(try await $0.download()) }
            .exportingCondition { $0.type.conforms(to: .pdf) }
            .suggestedFileName { $0.filename }
        FileRepresentation(exportedContentType: .data) { SentTransferredFile(try await $0.download()) }
            .suggestedFileName { $0.filename }
    }
}
