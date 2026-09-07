import AppKit
import SwiftUI
@preconcurrency import LinkPresentation

struct MessageLinkPreview: View {
    private let cardWidth: CGFloat = 280
    private let imageHeight: CGFloat = 158

    let url: URL
    let shouldLoad: Bool

    @State private var metadata: LPLinkMetadata?
    @State private var previewImage: NSImage?
    @State private var requested = false
    @State private var failed = false

    var body: some View {
        Group {
            if let metadata {
                Button {
                    NSWorkspace.shared.open(metadata.originalURL ?? metadata.url ?? url)
                } label: {
                    VStack(alignment: .leading, spacing: 0) {
                        ZStack {
                            Color.black.opacity(0.28)
                            if let previewImage {
                                Image(nsImage: previewImage)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: cardWidth, height: imageHeight, alignment: .topLeading)
                                    .clipped()
                                    .transition(.opacity)
                            } else {
                                Image(systemName: "link")
                                    .font(.system(size: 26, weight: .light))
                                    .foregroundStyle(.secondary)
                            }
                            if isYouTubeLink {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(14)
                                    .background(.black.opacity(0.7), in: Circle())
                            }
                        }
                        .frame(width: cardWidth, height: imageHeight)
                        .clipped()

                        VStack(alignment: .leading, spacing: 4) {
                            Text(title(for: metadata))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text(siteLabel)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .padding(.horizontal, 11)
                        .padding(.vertical, 9)
                        .frame(width: cardWidth, alignment: .leading)
                        .frame(minHeight: 62, alignment: .leading)
                    }
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(.white.opacity(0.12), lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open link: \(title(for: metadata))")
            } else if requested && !failed {
                HStack(spacing: 9) {
                    ProgressView()
                        .controlSize(.small)
                    Text(url.host ?? url.absoluteString)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: cardWidth, height: 54)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .onChange(of: shouldLoad, initial: true) { _, visible in
            guard visible else { return }
            requestMetadata()
        }
    }

    private func requestMetadata() {
        guard !requested else { return }
        requested = true
        LinkPreviewMetadataCache.shared.load(url) { result in
            metadata = result
            failed = result == nil
            guard let result,
                  let provider = result.imageProvider ?? result.iconProvider else { return }
            LinkPreviewMetadataCache.shared.loadImage(for: url, provider: provider) { image in
                withAnimation(.easeOut(duration: 0.15)) {
                    previewImage = image
                }
            }
        }
    }

    private func title(for metadata: LPLinkMetadata) -> String {
        metadata.title ?? url.host ?? url.absoluteString
    }

    private var siteLabel: String {
        let host = url.host ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private var isYouTubeLink: Bool {
        let host = url.host?.lowercased() ?? ""
        return host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com")
    }
}

@MainActor
private final class LinkPreviewMetadataCache {
    static let shared = LinkPreviewMetadataCache()

    private let cache = NSCache<NSURL, LPLinkMetadata>()
    private let imageCache = NSCache<NSURL, NSImage>()
    private var failedURLs = Set<URL>()
    private var pending: [URL: [(LPLinkMetadata?) -> Void]] = [:]
    private var providers: [URL: LPMetadataProvider] = [:]
    private var pendingImages: [URL: [(NSImage?) -> Void]] = [:]

    private init() {
        cache.countLimit = 128
        imageCache.countLimit = 128
    }

    func loadImage(for url: URL, provider: NSItemProvider, completion: @escaping (NSImage?) -> Void) {
        if let image = imageCache.object(forKey: url as NSURL) {
            completion(image)
            return
        }
        if pendingImages[url] != nil {
            pendingImages[url]?.append(completion)
            return
        }

        pendingImages[url] = [completion]
        provider.loadObject(ofClass: NSImage.self) { [weak self] object, _ in
            Task { @MainActor in
                self?.finishImage(url, image: object as? NSImage)
            }
        }
    }

    func load(_ url: URL, completion: @escaping (LPLinkMetadata?) -> Void) {
        if let metadata = cache.object(forKey: url as NSURL) {
            completion(metadata)
            return
        }
        if failedURLs.contains(url) {
            completion(nil)
            return
        }
        if pending[url] != nil {
            pending[url]?.append(completion)
            return
        }

        pending[url] = [completion]
        let provider = LPMetadataProvider()
        provider.timeout = 12
        providers[url] = provider
        provider.startFetchingMetadata(for: url) { [weak self] metadata, error in
            Task { @MainActor in
                self?.finish(url, metadata: error == nil ? metadata : nil)
            }
        }
    }

    private func finish(_ url: URL, metadata: LPLinkMetadata?) {
        providers[url] = nil
        if let metadata {
            cache.setObject(metadata, forKey: url as NSURL)
        } else {
            failedURLs.insert(url)
        }
        let completions = pending.removeValue(forKey: url) ?? []
        completions.forEach { $0(metadata) }
    }

    private func finishImage(_ url: URL, image: NSImage?) {
        if let image {
            imageCache.setObject(image, forKey: url as NSURL)
        }
        let completions = pendingImages.removeValue(forKey: url) ?? []
        completions.forEach { $0(image) }
    }
}
