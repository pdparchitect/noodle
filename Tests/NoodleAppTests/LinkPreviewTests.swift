import AppKit
import SwiftUI
import Observation
import XCTest
@preconcurrency import LinkPresentation
@testable import Noodle

@MainActor private final class LinkLoadFixture {
    let clock = RuntimeClockFixture()
    var metadata: [(URL, (LPLinkMetadata?) -> Void)] = []
    var images: [(NSItemProvider, (NSImage?) -> Void)] = []
    var metadataCancellations = 0
    var imageCancellations = 0
    lazy var cache = LinkPreviewMetadataCache(fetchMetadata: { [weak self] url, _, completion in
        self?.metadata.append((url, completion))
        return { [weak self] in self?.metadataCancellations += 1 }
    }, fetchImage: { [weak self] provider, completion in
        self?.images.append((provider, completion))
        return { [weak self] in self?.imageCancellations += 1 }
    }, sleep: { [clock] in try await clock.sleep($0) })
    func result(_ title: String, image: Bool = false, icon: Bool = false) -> LPLinkMetadata {
        let value = LPLinkMetadata(); value.title = title
        if image { value.imageProvider = NSItemProvider() }
        if icon { value.iconProvider = NSItemProvider() }
        return value
    }
}

@MainActor @Observable private final class LinkSelection {
    var url = URL(string: "https://www.example.com/first")!
    var visible = false
}

@MainActor final class LinkPreviewTests: HiddenViewTests {
    private let first = URL(string: "https://example.com/first")!
    private let second = URL(string: "https://example.com/second")!
    private func loader() -> LinkLoadFixture {
        let f = LinkLoadFixture(); addTeardownBlock { @MainActor in f.clock.releaseAll() }; return f
    }

    func testConcurrentRequestsShareOneFetchAndCompletedResultsAreCached() async throws {
        let f = loader(); var results: [LinkPreviewMetadataCache.Result] = []
        f.cache.load(first) { results.append($0) }; f.cache.load(first) { results.append($0) }
        XCTAssertEqual(f.metadata.count, 1)
        let metadata = f.result("Shared result")
        f.metadata[0].1(metadata)
        try await wait { results.count == 2 }
        XCTAssertTrue(results[0] === results[1]); XCTAssertTrue(results[0].metadata === metadata)
        f.cache.load(first) { results.append($0) }
        XCTAssertEqual(results.count, 3); XCTAssertTrue(results[0] === results[2])
        XCTAssertEqual(f.metadata.count, 1); XCTAssertEqual(f.metadataCancellations, 1)
    }

    func testImageProviderTakesPrecedenceOverIconAndImageIsCached() async throws {
        let f = loader(); var results: [LinkPreviewMetadataCache.Result] = []
        f.cache.load(first) { results.append($0) }
        let metadata = f.result("With image", image: true, icon: true)
        f.metadata[0].1(metadata)
        try await wait { f.images.count == 1 }
        XCTAssertTrue(f.images[0].0 === metadata.imageProvider); XCTAssertTrue(results.isEmpty)
        let image = NSImage(size: .init(width: 20, height: 20))
        f.images[0].1(image)
        try await wait { results.count == 1 }
        XCTAssertTrue(results[0].image === image)
        XCTAssertEqual(f.metadataCancellations, 1); XCTAssertEqual(f.imageCancellations, 1)
        f.cache.load(first) { results.append($0) }
        XCTAssertTrue(results[1].image === image); XCTAssertEqual(f.images.count, 1)
    }

    func testMissingImageFallsBackToMetadataAndUsesIconWhenAvailable() async throws {
        let f = loader(); var result: LinkPreviewMetadataCache.Result?
        f.cache.load(first) { result = $0 }
        let metadata = f.result("Icon only", icon: true)
        f.metadata[0].1(metadata)
        try await wait { f.images.count == 1 }
        XCTAssertTrue(f.images[0].0 === metadata.iconProvider)
        f.images[0].1(nil)
        try await wait { result != nil }
        XCTAssertTrue(result?.metadata === metadata); XCTAssertNil(result?.image)
    }

    func testFailedMetadataIsCachedWithoutStartingARetryLoop() async throws {
        let f = loader(); var results: [LinkPreviewMetadataCache.Result] = []
        f.cache.load(first) { results.append($0) }; f.metadata[0].1(nil)
        try await wait { results.count == 1 }
        for _ in 0..<3 { f.cache.load(first) { results.append($0) } }
        XCTAssertEqual(results.count, 4); XCTAssertEqual(f.metadata.count, 1)
        XCTAssertTrue(results.allSatisfy { $0.metadata == nil && $0.image == nil })
        XCTAssertTrue(f.images.isEmpty)
    }

    func testMetadataTimeoutCompletesEveryWaiterAndIgnoresLateSuccess() async throws {
        let f = loader(); var results: [LinkPreviewMetadataCache.Result] = []
        f.cache.load(first, timeout: 5) { results.append($0) }
        f.cache.load(first, timeout: 30) { results.append($0) }
        let deadline = try await f.clock.next(.seconds(5)); deadline.resolve(.success(()))
        try await wait { results.count == 2 }
        XCTAssertEqual(f.metadataCancellations, 1)
        f.metadata[0].1(f.result("Too late", image: true))
        for _ in 0..<5 { await Task.yield() }
        f.cache.load(first) { results.append($0) }
        XCTAssertEqual(results.count, 3); XCTAssertTrue(results.allSatisfy { $0.metadata == nil })
        XCTAssertTrue(f.images.isEmpty)
    }

    func testOneDeadlineCoversImageLoadingAndLateImageCannotReplaceFallback() async throws {
        let f = loader(); var results: [LinkPreviewMetadataCache.Result] = []
        f.cache.load(first, timeout: 5) { results.append($0) }
        let metadata = f.result("Image timed out", image: true)
        f.metadata[0].1(metadata); try await wait { f.images.count == 1 }
        let deadline = try await f.clock.next(.seconds(5)); deadline.resolve(.success(()))
        try await wait { results.count == 1 }
        XCTAssertTrue(results[0].metadata === metadata); XCTAssertNil(results[0].image)
        XCTAssertEqual(f.metadataCancellations, 1); XCTAssertEqual(f.imageCancellations, 1)
        f.images[0].1(NSImage(size: .init(width: 20, height: 20)))
        for _ in 0..<5 { await Task.yield() }
        f.cache.load(first) { results.append($0) }
        XCTAssertEqual(results.count, 2); XCTAssertNil(results[1].image)
    }

    func testCompletingOneURLDoesNotCancelAnotherURLsDeadline() async throws {
        let f = loader(); var a: LinkPreviewMetadataCache.Result?, b: LinkPreviewMetadataCache.Result?
        f.cache.load(first, timeout: 5) { a = $0 }; f.cache.load(second, timeout: 9) { b = $0 }
        f.metadata[0].1(f.result("First")); try await wait { a != nil }
        XCTAssertNil(b)
        let deadline = try await f.clock.next(.seconds(9)); deadline.resolve(.success(()))
        try await wait { b != nil }
        XCTAssertEqual(a?.metadata?.title, "First"); XCTAssertNil(b?.metadata)
        XCTAssertEqual(f.metadataCancellations, 2)
    }

    func testPreviewLoadsOnlyWhenVisibleAndOpensItsLink() async throws {
        let f = loader(), selection = LinkSelection(); var opened: [URL] = []
        let view = host(LinkFixtureView(selection: selection, cache: f.cache, openURL: { opened.append($0) }))
        _ = try await control("Open link: www.example.com", in: view)
        XCTAssertTrue(f.metadata.isEmpty)
        selection.visible = true
        try await wait { f.metadata.count == 1 }
        f.metadata[0].1(f.result("Article title"))
        press(try await control("Open link: Article title", in: view))
        XCTAssertEqual(opened, [selection.url])
        selection.visible = false; await Task.yield(); selection.visible = true
        _ = try await control("Open link: Article title", in: view)
        XCTAssertEqual(f.metadata.count, 1)
    }

    func testRecreatedPreviewRendersCachedImageBeforeBecomingVisible() async throws {
        let f = loader(); var completed = false
        f.cache.load(first) { _ in completed = true }
        f.metadata[0].1(f.result("Cached article", image: true))
        try await wait { f.images.count == 1 }
        let image = NSImage(size: .init(width: 40, height: 40), flipped: false) { rect in
            NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1).setFill(); rect.fill(); return true
        }
        f.images[0].1(image)
        try await wait { completed }
        let reference = ImageRenderer(content: Image(nsImage: image).resizable().frame(width: 280, height: 158))
        let referenceBitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(reference.cgImage))
        let expected = try XCTUnwrap(referenceBitmap.colorAt(x: 140, y: 79)?.usingColorSpace(.sRGB))

        // Lazy rows can be recreated before their visibility callback arrives.
        // The very first frame must contain the cached image, without a fade-in.
        for _ in 0..<3 {
            let preview = MessageLinkPreview(url: first, shouldLoad: false, cache: f.cache)
            let renderer = ImageRenderer(content: preview)
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            let color = try XCTUnwrap(bitmap.colorAt(x: 140, y: 79)?.usingColorSpace(.sRGB))
            XCTAssertEqual(color.blueComponent, expected.blueComponent, accuracy: 0.01)
            XCTAssertEqual(color.redComponent, expected.redComponent, accuracy: 0.01)
            XCTAssertEqual(color.greenComponent, expected.greenComponent, accuracy: 0.01)
            let view = host(preview)
            _ = try await control("Open link: Cached article", in: view)
        }
        XCTAssertEqual(f.metadata.count, 1)
        XCTAssertEqual(f.images.count, 1)
    }

    func testHiddenReusedPreviewRestoresCachedURLAndRejectsItsOldRequest() async throws {
        let f = loader(), selection = LinkSelection(); var completed = false
        f.cache.load(second) { _ in completed = true }
        f.metadata[0].1(f.result("Cached replacement"))
        try await wait { completed }

        selection.visible = true
        let view = host(LinkFixtureView(selection: selection, cache: f.cache, openURL: { _ in }))
        try await wait { f.metadata.count == 2 }
        selection.visible = false
        selection.url = second
        _ = try await control("Open link: Cached replacement", in: view)
        f.metadata[1].1(f.result("Retired article"))
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(hasControl("Open link: Cached replacement", in: view))
        XCTAssertFalse(hasControl("Open link: Retired article", in: view))
        selection.visible = true
        _ = try await control("Open link: Cached replacement", in: view)
        XCTAssertEqual(f.metadata.count, 2)
    }

    func testReusedPreviewResetsOnURLChangeAndRejectsTheOldResult() async throws {
        let f = loader(), selection = LinkSelection(); selection.visible = true
        let view = host(LinkFixtureView(selection: selection, cache: f.cache, openURL: { _ in }))
        try await wait { f.metadata.count == 1 }
        selection.url = second
        try await wait { f.metadata.count == 2 }
        XCTAssertEqual(f.metadata.map(\.0), [URL(string: "https://www.example.com/first")!, second])
        f.metadata[1].1(f.result("Replacement"))
        _ = try await control("Open link: Replacement", in: view)
        f.metadata[0].1(f.result("Retired"))
        for _ in 0..<5 { await Task.yield() }
        XCTAssertTrue(hasControl("Open link: Replacement", in: view))
        XCTAssertFalse(hasControl("Open link: Retired", in: view))
    }

    func testChangingAHiddenCardsURLClearsItsOldTitleAndDefersTheNextFetch() async throws {
        let f = loader(), selection = LinkSelection(); selection.visible = true
        let view = host(LinkFixtureView(selection: selection, cache: f.cache, openURL: { _ in }))
        try await wait { f.metadata.count == 1 }
        f.metadata[0].1(f.result("Old article"))
        _ = try await control("Open link: Old article", in: view)
        selection.visible = false
        selection.url = URL(string: "https://other.example.com/new")!
        _ = try await control("Open link: other.example.com", in: view)
        XCTAssertEqual(f.metadata.count, 1)
        selection.visible = true
        try await wait { f.metadata.count == 2 }
        f.metadata[1].1(nil)
        _ = try await control("Open link: other.example.com", in: view)
    }
}

@MainActor private struct LinkFixtureView: View {
    let selection: LinkSelection
    let cache: LinkPreviewMetadataCache
    let openURL: (URL) -> Void
    var body: some View { MessageLinkPreview(url: selection.url, shouldLoad: selection.visible, cache: cache, openURL: openURL) }
}
