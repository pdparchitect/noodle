import SwiftUI
@preconcurrency import LinkPresentation

struct MessageLinkPreview: View {
    let url: URL
    let shouldLoad: Bool

    @State private var metadata: LPLinkMetadata?
    @State private var requested = false
    @State private var failed = false

    var body: some View {
        Group {
            if let metadata {
                NativeLinkPreview(metadata: metadata)
                    .frame(width: 360, height: 92)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(.white.opacity(0.12), lineWidth: 1)
                    }
            } else if requested && !failed {
                HStack(spacing: 9) {
                    ProgressView()
                        .controlSize(.small)
                    Text(url.host ?? url.absoluteString)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 360, height: 54)
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
        }
    }
}

private struct NativeLinkPreview: NSViewRepresentable {
    let metadata: LPLinkMetadata

    func makeNSView(context: Context) -> LPLinkView {
        LPLinkView(metadata: metadata)
    }

    func updateNSView(_ linkView: LPLinkView, context: Context) {
        linkView.metadata = metadata
    }
}

@MainActor
private final class LinkPreviewMetadataCache {
    static let shared = LinkPreviewMetadataCache()

    private let cache = NSCache<NSURL, LPLinkMetadata>()
    private var failedURLs = Set<URL>()
    private var pending: [URL: [(LPLinkMetadata?) -> Void]] = [:]
    private var providers: [URL: LPMetadataProvider] = [:]

    private init() {
        cache.countLimit = 128
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
}
