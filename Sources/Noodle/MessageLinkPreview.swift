import AppKit
import SwiftUI
@preconcurrency import LinkPresentation

struct MessageLinkPreview: View {
    private let cardWidth: CGFloat = 280
    private let imageHeight: CGFloat = 158
    private let cardHeight: CGFloat = 220

    let url: URL
    let shouldLoad: Bool

    @State private var metadata: LPLinkMetadata?
    @State private var previewImage: NSImage?
    @State private var requested = false
    @State private var loading = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
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
                    } else if loading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "link")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(.secondary)
                    }
                    if isYouTubeLink, metadata != nil {
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
                    Text(title)
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
                .frame(minHeight: cardHeight - imageHeight, alignment: .leading)
            }
            .frame(width: cardWidth, height: cardHeight, alignment: .top)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.white.opacity(0.12), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open link: \(title)")
        .onChange(of: shouldLoad, initial: true) { _, visible in
            guard visible else { return }
            requestMetadata()
        }
    }

    private func requestMetadata() {
        guard !requested else { return }
        requested = true
        loading = true
        LinkPreviewMetadataCache.shared.load(url) { result in
            metadata = result.metadata
            loading = false
            withAnimation(.easeOut(duration: 0.15)) {
                previewImage = result.image
            }
        }
    }

    private var title: String {
        metadata?.title ?? url.host ?? url.absoluteString
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

enum LinkPreviewSettings {
    static let timeoutKey = "Noodle.linkPreview.timeoutSeconds"
    static let defaultTimeout = 10
    static let timeoutOptions = [5, 10, 20, 30]
    static func timeout(in defaults: UserDefaults = .standard) -> TimeInterval {
        let value = defaults.object(forKey: timeoutKey) as? Int ?? defaultTimeout
        return TimeInterval(min(30, max(5, value)))
    }
}

@MainActor
final class LinkPreviewMetadataCache {
    static let shared = LinkPreviewMetadataCache()
    final class Result: NSObject {
        let metadata: LPLinkMetadata?
        let image: NSImage?
        init(metadata: LPLinkMetadata?, image: NSImage?) {
            self.metadata = metadata
            self.image = image
        }
    }
    private final class Request {
        var metadata: LPLinkMetadata?
        var completions: [(Result) -> Void] = []
        var cancellations: [() -> Void] = []
        var deadline: Task<Void, Never>?
    }
    typealias MetadataLoader = (URL, TimeInterval, @escaping (LPLinkMetadata?) -> Void) -> (() -> Void)
    typealias ImageLoader = (NSItemProvider, @escaping (NSImage?) -> Void) -> (() -> Void)
    private let fetchMetadata: MetadataLoader
    private let fetchImage: ImageLoader
    private let cache = NSCache<NSURL, Result>()
    private var pending: [URL: Request] = [:]

    init(fetchMetadata: @escaping MetadataLoader = LinkPreviewMetadataCache.nativeMetadata,
         fetchImage: @escaping ImageLoader = LinkPreviewMetadataCache.nativeImage) {
        self.fetchMetadata = fetchMetadata
        self.fetchImage = fetchImage
        cache.countLimit = 128
    }
    func load(_ url: URL, timeout: TimeInterval = LinkPreviewSettings.timeout(), completion: @escaping (Result) -> Void) {
        if let result = cache.object(forKey: url as NSURL) {
            completion(result)
            return
        }
        if let request = pending[url] {
            request.completions.append(completion)
            return
        }
        let request = Request()
        request.completions = [completion]
        pending[url] = request
        // One deadline covers metadata AND its image, independently of whether
        // Apple's callbacks arrive. Every terminal outcome stops the spinner.
        request.deadline = Task { [weak self, weak request] in
            try? await Task.sleep(for: .seconds(max(0.01, timeout)))
            guard !Task.isCancelled, let request else { return }
            self?.finish(url, request: request, image: nil)
        }
        request.cancellations.append(fetchMetadata(url, timeout) { [weak self, weak request] metadata in
            Task { @MainActor in
                guard let self, let request, self.pending[url] === request else { return }
                request.metadata = metadata
                guard let provider = metadata?.imageProvider ?? metadata?.iconProvider else {
                    self.finish(url, request: request, image: nil)
                    return
                }
                request.cancellations.append(self.fetchImage(provider) { [weak self, weak request] image in
                    Task { @MainActor in
                        guard let request else { return }
                        self?.finish(url, request: request, image: image)
                    }
                })
            }
        })
    }
    private func finish(_ url: URL, request: Request, image: NSImage?) {
        guard pending[url] === request else { return }
        pending[url] = nil
        request.deadline?.cancel()
        request.cancellations.forEach { $0() }
        let result = Result(metadata: request.metadata, image: image)
        // Cache failures too: rebuilding visible rows must not start retry loops.
        cache.setObject(result, forKey: url as NSURL)
        request.completions.forEach { $0(result) }
    }
    nonisolated static func nativeMetadata(_ url: URL, timeout: TimeInterval, completion: @escaping (LPLinkMetadata?) -> Void) -> (() -> Void) {
        let provider = LPMetadataProvider()
        provider.timeout = timeout
        provider.startFetchingMetadata(for: url) { metadata, error in
            completion(error == nil ? metadata : nil)
        }
        return { provider.cancel() }
    }
    nonisolated static func nativeImage(_ provider: NSItemProvider, completion: @escaping (NSImage?) -> Void) -> (() -> Void) {
        let progress = provider.loadObject(ofClass: NSImage.self) { object, _ in
            completion(object as? NSImage)
        }
        return { progress.cancel() }
    }
}
