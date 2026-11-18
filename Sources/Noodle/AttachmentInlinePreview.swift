import CryptoKit
import QuickLookThumbnailing
import AppletBridge
import ComputerBridge
import BrowserBridge
import ImageIO
import SwiftUI
import NoodleCore
import UniformTypeIdentifiers


// How an attachment shows in a message: its tile, picture and symbol, and which open together in
// Quick Look. Nothing here reads the store, so another app on Noodle's core can compile this file.

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

    /// Plain files open in Quick Look together; links, voice messages and annotations open on their own.
    var joinsPreviewGallery: Bool { annotation == nil && url == nil && voice == nil && !opensInCompanion }

    /// The files Quick Look pages through when one attachment of a message opens, and where it starts.
    static func previewGallery(opening attachment: ConversationAttachment,
                               among group: [ConversationAttachment]) -> (items: [ConversationAttachment], index: Int) {
        let items = attachment.joinsPreviewGallery ? group.filter(\.joinsPreviewGallery) : []
        guard let index = items.firstIndex(where: { $0.id == attachment.id }) else { return ([attachment], 0) }
        return (items, index)
    }

    var companionKind: String {
        switch companion {
        case .browser: "Browser"
        case .computer: "Computer"
        default: "Noodlet"
        }
    }

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

struct AttachmentInlinePreview: View {
    let attachment: ConversationAttachment
    let fileURL: URL
    /// For a file only its Hub has, the Hub's picture of it, fetched when the bubble shows.
    let hubPreview: (() async -> URL?)?
    let shouldLoad: Bool
    let isSelected: Bool
    let select: () -> Void
    let preview: () -> Void
    /// For a voice message, whether its transcript is open.
    let showsTranscript: Binding<Bool>?
    private let imagePreviewSize: CGSize
    private let displaysAsImage: Bool

    /// How long a row off screen keeps its picture, so scrolling back and forth does not reload it.
    static let releaseDelay: Duration = .seconds(5)

    @State private var thumbnail: NSImage?
    @State private var thumbnailUnavailable = false
    /// The shape of the Hub's picture, once it came.
    @State private var hubPictureSize: CGSize?
    /// What a patch file reads as, once read; nil while it is read and for a file that is not one.
    @State private var patch: Patch?
    @State private var isNotAPatch = false
    @FocusState private var isFocused: Bool

    init(
        attachment: ConversationAttachment,
        fileURL: URL,
        hubPreview: (() async -> URL?)? = nil,
        shouldLoad: Bool,
        isSelected: Bool,
        select: @escaping () -> Void,
        preview: @escaping () -> Void,
        showsTranscript: Binding<Bool>? = nil
    ) {
        self.attachment = attachment
        self.fileURL = fileURL
        self.hubPreview = hubPreview
        self.shouldLoad = shouldLoad
        self.isSelected = isSelected
        self.select = select
        self.preview = preview
        self.showsTranscript = showsTranscript
        // A file not here yet is not read, so nothing is remembered of it once it comes.
        displaysAsImage = attachment.mediaType.hasPrefix("image/") || (hubPreview == nil && AttachmentThumbnailCache.isImage(fileURL))
        imagePreviewSize = displaysAsImage && hubPreview == nil
            ? AttachmentThumbnailCache.previewSize(for: fileURL)
            : CGSize(width: 300, height: 200)
    }

    var body: some View {
        if let voice = attachment.voice, attachment.mediaType.hasPrefix("audio/") {
            VoiceMessagePlayer(url: fileURL, voice: voice, shouldPlay: shouldLoad, showsTranscript: showsTranscript)
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
            } else if let webLink {
                // A shared web page looks like one unfurled from a message, not like its bookmark file.
                LinkPreviewCard(url: webLink, shouldLoad: shouldLoad)
            } else if let patch {
                patchPreview(patch)
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
            // A transcript keeps every row it built, so a row scrolled away gives its picture back
            // after a while; the cache or the Caches folder returns it when the row shows again.
            if !shouldLoad {
                guard thumbnail != nil, (try? await Task.sleep(for: Self.releaseDelay)) != nil else { return }
                thumbnail = nil
                return
            }
            guard attachment.url.flatMap(NoodletLink.id) == nil, webLink == nil,
                  attachment.annotation == nil || attachment.mediaType.hasPrefix("image/") else { return }
            if attachment.isPatchFile, !isNotAPatch, hubPreview == nil {
                if let read = await PatchCache.patch(at: fileURL) {
                    withAnimation(.easeOut(duration: 0.15)) { patch = read }
                    return
                }
                isNotAPatch = true
            }
            await loadThumbnail()
        }
    }

    private var webLink: URL? {
        guard attachment.card == nil else { return nil }
        return attachment.url.flatMap { MessageLink.publicWebURL(from: $0, preservingFragment: true) }
    }

    private var openHint: String {
        if attachment.isBrowserLink { return "Click or press Space to open in Noodle Browser" }
        if attachment.isComputerLink { return "Click or press Space to open in Noodle Computer" }
        if attachment.isNoodletLink { return "Click or press Space to open in \(AppletBuildIdentity.current.appName)" }
        if patch != nil { return "Click or press Space to review the changes" }
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
                    Text(detail).font(.system(size: 9, design: .monospaced)).foregroundStyle(.primary.opacity(0.8))
                        .lineLimit(10).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(10)
                } else {
                    Image(systemName: attachment.previewSymbolName)
                        .font(.system(size: 38, weight: .light)).foregroundStyle(.primary.opacity(0.42))
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

    /// A patch: what changed most, in the place of a document's thumbnail, and its title and totals.
    private func patchPreview(_ patch: Patch) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ZStack {
                Color.black.opacity(0.16)
                PatchCardPicture(patch: patch, filename: attachment.originalFilename)
            }
            .frame(maxWidth: .infinity).frame(height: 165)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .accessibilityHidden(true)
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 16, weight: .medium))
                VStack(alignment: .leading, spacing: 1) {
                    Text(patch.title(filename: attachment.originalFilename)).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    Text(patch.totals).font(.system(size: 9.5)).opacity(0.72)
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
            if note.region != nil {
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
            // A capture around a field marks it and quotes its text too.
            if let quote = note.quote {
                Text(quote).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    .padding(.leading, 9)
                    .overlay(alignment: .leading) { Rectangle().fill(.orange.opacity(0.6)).frame(width: 2) }
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
        .aspectRatio(hubPictureSize ?? imagePreviewSize, contentMode: .fit)
        .frame(idealWidth: (hubPictureSize ?? imagePreviewSize).width, maxWidth: (hubPictureSize ?? imagePreviewSize).width)
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
                        .foregroundStyle(.primary.opacity(thumbnailUnavailable ? 0.72 : 0.42))
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
        if let hubPreview {
            await loadHubPicture(hubPreview)
            return
        }
        let key = fileURL as NSURL
        if let cached = AttachmentThumbnailCache.shared.object(forKey: key) {
            thumbnail = cached
            return
        }
        if attachment.card != nil {
            let attachment = attachment, folder = fileURL.deletingLastPathComponent()
            if let result = await Task.detached(priority: .utility, operation: {
                WorkspaceRepository.cardImage(of: attachment, in: folder).flatMap(AttachmentThumbnailCache.cardThumbnail)
            }).value {
                guard !Task.isCancelled else { return }
                AttachmentThumbnailCache.shared.setObject(result, forKey: key); thumbnail = result
            } else { thumbnailUnavailable = true }
            return
        }

        if displaysAsImage,
           let generated = await Task.detached(priority: .utility, operation: {
               AttachmentThumbnailCache.thumbnail(for: fileURL)
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

    /// The Hub's picture of a file not downloaded yet, in place of one made from the file.
    @MainActor
    private func loadHubPicture(_ hubPreview: () async -> URL?) async {
        guard let url = await hubPreview() else {
            thumbnailUnavailable = true
            return
        }
        let key = url as NSURL
        let picture: NSImage?
        if let cached = AttachmentThumbnailCache.shared.object(forKey: key) { picture = cached }
        else { picture = await Task.detached(priority: .utility) { AttachmentThumbnailCache.thumbnail(for: url) }.value }
        guard !Task.isCancelled else { return }
        guard let picture else {
            thumbnailUnavailable = true
            return
        }
        AttachmentThumbnailCache.shared.setObject(picture, forKey: key)
        if displaysAsImage { hubPictureSize = AttachmentThumbnailCache.previewSize(for: url) }
        withAnimation(.easeOut(duration: 0.15)) { thumbnail = picture }
    }
}

/// Decoded pictures kept up to `limit` bytes, the longest unseen let go first, and all of them
/// when the system runs short of memory.
@MainActor
final class ThumbnailMemory {
    private let limit: Int
    private var images: [NSURL: (image: NSImage, cost: Int, used: Int)] = [:]
    private var total = 0
    private var clock = 0
    private let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)

    init(limit: Int) {
        self.limit = limit
        pressure.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.removeAllObjects() } }
        pressure.resume()
    }

    func object(forKey key: NSURL) -> NSImage? {
        guard let entry = images[key] else { return nil }
        clock += 1
        images[key]?.used = clock
        return entry.image
    }

    func setObject(_ image: NSImage, forKey key: NSURL) {
        removeObject(forKey: key)
        let cost = image.representations.reduce(0) { $0 + $1.pixelsWide * $1.pixelsHigh * 4 }
        clock += 1
        images[key] = (image, cost, clock)
        total += cost
        while total > limit, images.count > 1,
              let oldest = images.filter({ $0.key != key }).min(by: { $0.value.used < $1.value.used })?.key {
            removeObject(forKey: oldest)
        }
    }

    func removeObject(forKey key: NSURL) {
        if let entry = images.removeValue(forKey: key) { total -= entry.cost }
    }

    func removeAllObjects() {
        images.removeAll()
        total = 0
    }
}

@MainActor
enum AttachmentThumbnailCache {
    static let shared = ThumbnailMemory(limit: 64 << 20)
    private static var previewSizes: [URL: CGSize] = [:]
    private static let counts = Counts()

    /// Full decodes of an original and reads of its header, for tests.
    nonisolated static var decodes: Int { counts.value(\.decodes) }
    static var headerReads: Int { counts.value(\.headerReads) }

    private static var imageChecks: [URL: Bool] = [:]

    /// Bubbles are rebuilt many times while scrolling; an attachment's file does not change.
    static func isImage(_ url: URL) -> Bool {
        if let known = imageChecks[url] { return known }
        counts.add(\.headerReads)
        let isImage: Bool
        if let source = imageSource(for: url),
           let identifier = CGImageSourceGetType(source) as String?,
           let type = UTType(identifier) {
            isImage = type.conforms(to: .image)
        } else {
            isImage = false
        }
        imageChecks[url] = isImage
        return isImage
    }

    /// The widest a preview is shown, in pixels on a Retina display.
    nonisolated static let thumbnailPixels = 600

    /// Memory is reclaimed under pressure, and decoding the original again is the expensive
    /// part of scrolling back to a picture, so a small copy is also kept in the Caches folder,
    /// which macOS may empty. A changed original has a different key and gets a new copy.
    nonisolated static func thumbnail(for url: URL, cacheDirectory: URL? = nil) -> NSImage? {
        guard let directory = cacheDirectory ?? defaultCacheDirectory, let key = cacheKey(for: url) else {
            return generateImageThumbnail(for: url).map { NSImage(cgImage: $0, size: .zero) }
        }
        let copy = directory.appendingPathComponent(key + ".png")
        if let source = CGImageSourceCreateWithURL(copy as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) {
            return NSImage(cgImage: image, size: .zero)
        }
        guard let image = generateImageThumbnail(for: url) else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appendingPathComponent(key + "-" + UUID().uuidString + ".partial")
        if let destination = CGImageDestinationCreateWithURL(partial as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            if CGImageDestinationFinalize(destination), rename(partial.path, copy.path) == 0 { return NSImage(cgImage: image, size: .zero) }
        }
        try? FileManager.default.removeItem(at: partial)
        return NSImage(cgImage: image, size: .zero)
    }

    /// The picture a browser tab or computer card carries.
    nonisolated static func cardThumbnail(from data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }

    nonisolated private static var defaultCacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "Noodle", isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
    }

    /// The original's path and the file it is now: a replaced or edited one gets a new key.
    nonisolated private static func cacheKey(for url: URL) -> String? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        let identity = "\(url.path)|\(info.st_dev)|\(info.st_ino)|\(info.st_size)|\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)|\(thumbnailPixels)"
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    nonisolated private static func generateImageThumbnail(for url: URL) -> CGImage? {
        counts.add(\.decodes)
        guard let source = imageSource(for: url) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
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

    private final class Counts: @unchecked Sendable {
        struct Values { var decodes = 0, headerReads = 0 }
        private let lock = NSLock()
        private var values = Values()
        func add(_ key: WritableKeyPath<Values, Int>) { lock.withLock { values[keyPath: key] += 1 } }
        func value(_ key: KeyPath<Values, Int>) -> Int { lock.withLock { values[keyPath: key] } }
    }

    nonisolated private static func imageSource(for url: URL) -> CGImageSource? {
        CGImageSourceCreateWithURL(
            url as CFURL,
            [kCGImageSourceShouldCache: false] as CFDictionary
        )
    }
}

// MARK: - Patch card

extension ConversationAttachment {
    /// A `.patch` or `.diff` file. It opens in a review when it reads as a patch, and in Quick Look when it does not.
    var isPatchFile: Bool {
        annotation == nil && url == nil && voice == nil && Patch.isPatchFile(name: originalFilename, mediaType: mediaType)
    }
}

/// The picture on a patch's card: its commits and who made them, and the files that changed most.
struct PatchCardPicture: View {
    let patch: Patch
    let filename: String
    static let shown = 6

    var body: some View {
        let files = patch.largestFiles(Self.shown)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 9, weight: .semibold))
                Text(patch.headline(filename: filename)).font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if patch.commits.count > 1 {
                    Text("\(patch.commits.count) commits").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(Color.accentColor, in: Capsule())
                }
            }
            .foregroundStyle(.secondary).padding(.bottom, 2)
            ForEach(Array(files)) { file in
                HStack(spacing: 5) {
                    Text(file.name).font(.system(size: 9.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    PatchChangeCounts(added: file.added, removed: file.removed, size: 9)
                }
            }
            if patch.fileCount > Self.shown {
                Text("+ \(patch.fileCount - Self.shown) more").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// "+148 −49", in green and red.
struct PatchChangeCounts: View {
    let added: Int
    let removed: Int
    var size: CGFloat = 11
    var dimmed = false

    var body: some View {
        HStack(spacing: 5) {
            Text("+\(added)").foregroundStyle(dimmed ? AnyShapeStyle(HierarchicalShapeStyle.secondary) : AnyShapeStyle(Color.green))
            Text(removed > 0 ? "−\(removed)" : "").foregroundStyle(dimmed ? AnyShapeStyle(HierarchicalShapeStyle.secondary) : AnyShapeStyle(Color.red))
                .frame(minWidth: size * 3, alignment: .leading)
        }
        .font(.system(size: size, design: .monospaced)).monospacedDigit()
    }
}

// MARK: - Window

/// Patches open for review, each in a window of its own in the frame of the other previews.
