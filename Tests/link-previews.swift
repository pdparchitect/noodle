import AppKit
import Foundation
@preconcurrency import LinkPresentation

@main
enum LinkPreviewChecks {
    @MainActor static func main() async {
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            fputs("Link preview regression checks hung\n", stderr)
            exit(1)
        }
        let url = URL(string: "https://example.invalid/preview")!
        var calls = 0
        let noImage = LinkPreviewMetadataCache(fetchMetadata: { _, _, done in
            calls += 1
            done(LPLinkMetadata())
            return {}
        }, fetchImage: { _, _ in preconditionFailure("No image must finish without loading one") })
        let textOnly = await result(noImage, url)
        precondition(textOnly.metadata != nil && textOnly.image == nil)
        _ = await result(noImage, url)
        precondition(calls == 1, "Text-only results must be cached")

        var cancelCount = 0
        var completions = 0
        var lateMetadata: ((LPLinkMetadata?) -> Void)?
        let stalled = LinkPreviewMetadataCache(fetchMetadata: { _, _, done in
            calls += 1
            lateMetadata = done
            return { cancelCount += 1 }
        })
        let fallback = await withCheckedContinuation { continuation in
            stalled.load(url, timeout: 0.03) { value in completions += 1; continuation.resume(returning: value) }
            stalled.load(url, timeout: 0.03) { _ in completions += 1 }
        }
        precondition(fallback.metadata == nil && completions == 2 && cancelCount == 1)
        lateMetadata?(LPLinkMetadata())
        await Task.yield()
        let cachedFailure = await result(stalled, url)
        precondition(cachedFailure.metadata == nil && calls == 2 && completions == 2)

        var cancelImage = false
        var lateImage: ((NSImage?) -> Void)?
        let metadata = LPLinkMetadata()
        metadata.title = "Text survives a stalled thumbnail"
        metadata.imageProvider = NSItemProvider(object: NSImage(size: NSSize(width: 2, height: 2)))
        let stalledImage = LinkPreviewMetadataCache(fetchMetadata: { _, _, done in
            done(metadata)
            return {}
        }, fetchImage: { _, done in
            lateImage = done
            return { cancelImage = true }
        })
        let partial = await result(stalledImage, url)
        precondition(partial.metadata === metadata && partial.image == nil && cancelImage)
        lateImage?(NSImage(size: NSSize(width: 2, height: 2)))
        await Task.yield()
        let cachedPartial = await result(stalledImage, url)
        precondition(cachedPartial.image == nil, "Late images must not resurrect an expired preview")

        let failedImage = LinkPreviewMetadataCache(fetchMetadata: { _, _, done in done(metadata); return {} },
                                                   fetchImage: { _, done in done(nil); return {} })
        let failedResult = await result(failedImage, url)
        precondition(failedResult.metadata != nil && failedResult.image == nil)
        let image = NSImage(size: NSSize(width: 2, height: 2))
        let success = LinkPreviewMetadataCache(fetchMetadata: { _, _, done in done(metadata); return {} },
                                               fetchImage: { _, done in done(image); return {} })
        let loaded = await result(success, url)
        precondition(loaded.image === image)
        print("Link preview checks passed: no image, failure, shared deadline, cancellation, deduplication, cache, late callbacks, success")
    }

    @MainActor static func result(_ cache: LinkPreviewMetadataCache, _ url: URL) async -> LinkPreviewMetadataCache.Result {
        await withCheckedContinuation { continuation in
            cache.load(url, timeout: 0.03) { continuation.resume(returning: $0) }
        }
    }
}
