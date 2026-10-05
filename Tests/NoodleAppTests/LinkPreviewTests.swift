import AppKit
import SwiftUI
import NoodleCore
import Observation
import XCTest
@preconcurrency import LinkPresentation
@testable import Noodle

@MainActor private final class LinkLoadFixture {
    let clock = RuntimeClockFixture()
    var metadata: [(URL, (LPLinkMetadata?) -> Void)] = []
    var images: [(NSItemProvider, (NSImage?) -> Void)] = []
    var maps: [(MapLink, (NSImage?) -> Void)] = []
    var metadataCancellations = 0
    var imageCancellations = 0
    var mapCancellations = 0
    lazy var cache = LinkPreviewMetadataCache(fetchMetadata: { [weak self] url, _, completion in
        self?.metadata.append((url, completion))
        return { [weak self] in self?.metadataCancellations += 1 }
    }, fetchImage: { [weak self] provider, completion in
        self?.images.append((provider, completion))
        return { [weak self] in self?.imageCancellations += 1 }
    }, fetchMap: { [weak self] link, _, completion in
        self?.maps.append((link, completion))
        return { [weak self] in self?.mapCancellations += 1 }
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

    /// Previews are kept on disk for a week: a relaunch shows them at once, and after a week they are fetched again.
    func testPreviewsAreKeptOnDiskForAWeek() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        var now = Date(timeIntervalSince1970: 1_000_000)
        var fetches = 0
        func launch(_ found: Bool = true) -> LinkPreviewMetadataCache {
            LinkPreviewMetadataCache(fetchMetadata: { _, _, completion in
                fetches += 1
                let value = LPLinkMetadata(); value.title = "Kept"; value.imageProvider = NSItemProvider()
                completion(found ? value : nil)
                return {}
            }, fetchImage: { _, completion in
                completion(NSImage(size: .init(width: 4, height: 4), flipped: false) { NSColor.red.setFill(); $0.fill(); return true })
                return {}
            }, fetchMap: { _, _, _ in {} }, folder: folder, now: { now })
        }
        var result: LinkPreviewMetadataCache.Result?
        let cache = launch()
        cache.load(first) { result = $0 }
        try await wait { result != nil }

        let relaunched = launch().cachedResult(for: first)
        XCTAssertEqual(relaunched?.metadata?.title, "Kept")
        XCTAssertEqual(relaunched?.image?.size, NSSize(width: 4, height: 4))
        XCTAssertEqual(fetches, 1)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1)
        now += 8 * 86_400
        _ = launch()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 0,
                       "A launch clears previews older than a week")
        XCTAssertNil(launch().cachedResult(for: first))

        var failed: LinkPreviewMetadataCache.Result?
        let failing = launch(false)
        failing.load(second) { failed = $0 }
        try await wait { failed != nil }
        XCTAssertNil(launch().cachedResult(for: second), "A failed preview is tried again after a relaunch")
    }

    /// Scrolled rows redraw their picture constantly; a full-size web image made each redraw decode it again.
    func testPreviewPicturesAreKeptNoLargerThanTheirCardShowsThem() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        func picture(_ width: Int, _ height: Int) -> NSImage {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            let image = NSImage(size: .init(width: width, height: height))
            image.addRepresentation(bitmap)
            return image
        }
        func pixels(_ image: NSImage?) -> CGSize? {
            image?.cgImage(forProposedRect: nil, context: nil, hints: nil).map { CGSize(width: $0.width, height: $0.height) }
        }
        let card = CGSize(width: LinkPreviewCard.cardWidth * 2, height: LinkPreviewCard.imageHeight * 2)
        for (url, width, height) in [(first, 2400, 1260), (second, 3000, 300)] {
            let cache = LinkPreviewMetadataCache(fetchMetadata: { _, _, completion in
                let value = LPLinkMetadata(); value.title = "Big"; value.imageProvider = NSItemProvider()
                completion(value)
                return {}
            }, fetchImage: { _, completion in
                completion(picture(width, height))
                return {}
            }, fetchMap: { _, _, _ in {} }, folder: folder)
            var result: LinkPreviewMetadataCache.Result?
            cache.load(url) { result = $0 }
            try await wait { result != nil }
            let reopened = LinkPreviewMetadataCache(fetchMetadata: { _, _, _ in {} }, folder: folder).cachedResult(for: url)
            for (name, size) in [("loaded", pixels(result?.image)), ("reopened", pixels(reopened?.image))] {
                let size = try XCTUnwrap(size, "The \(name) \(width)×\(height) preview lost its picture")
                XCTAssertLessThanOrEqual(min(size.width / card.width, size.height / card.height), 1.01,
                    "The \(name) \(width)×\(height) preview keeps a \(size) picture for a \(card) card")
                XCTAssertGreaterThanOrEqual(size.width, min(card.width, CGFloat(width)) - 1, "The \(name) picture no longer fills the card")
                XCTAssertGreaterThanOrEqual(size.height, min(card.height, CGFloat(height)) - 1, "The \(name) picture no longer fills the card")
                XCTAssertEqual(size.width / size.height, CGFloat(width) / CGFloat(height), accuracy: 0.05, "The \(name) picture is distorted")
            }
        }
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

    /// Starting a fetch blocks the main thread; one per row flying past froze scrolling for seconds.
    func testPreviewsScrolledPastDoNotStartFetching() async throws {
        let f = loader(), selection = LinkSelection()
        let view = host(LinkFixtureView(selection: selection, cache: f.cache, openURL: { _ in }))
        _ = try await control("Open link: www.example.com", in: view)
        for _ in 0..<5 {
            selection.visible = true
            try await Task.sleep(for: .milliseconds(30))
            selection.visible = false
            try await Task.sleep(for: .milliseconds(30))
        }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(f.metadata.isEmpty, "A preview only scrolled past started \(f.metadata.count) fetches")
        selection.visible = true
        try await wait { f.metadata.count == 1 }
    }

    func testWebLinkAttachmentLooksLikeAnUnfurledLink() throws {
        let url = URL(string: "https://www.example.com/\(UUID().uuidString)")!
        let link = ConversationAttachment(conversationID: UUID(), originalFilename: "www.example.com.webloc",
            storedFilename: "www.example.com.webloc", mediaType: "application/x-webloc", byteCount: 7, url: url)
        let attachment = AttachmentInlinePreview(attachment: link, fileURL: URL(fileURLWithPath: "/nonexistent.webloc"),
            shouldLoad: false, isSelected: false, select: {}, preview: {})
        let card = try XCTUnwrap(ImageRenderer(content: LinkPreviewCard(url: url, shouldLoad: false)).nsImage)
        let rendered = try XCTUnwrap(ImageRenderer(content: attachment).nsImage)
        XCTAssertEqual(rendered.size, card.size)
        XCTAssertEqual(rendered.tiffRepresentation, card.tiffRepresentation)
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

    func testAppleMapsLinksDescribeTheirPlaceOrRoute() {
        func link(_ string: String) -> MapLink? { MapLink(URL(string: string)!) }
        XCTAssertEqual(link("https://maps.apple.com/?saddr=Oakland&daddr=Ferry+Building&dirflg=w"),
                       MapLink(from: .address("Oakland"), to: .address("Ferry Building"), directions: true, transport: .walking))
        XCTAssertEqual(link("https://maps.apple.com/?daddr=37.7955,-122.3937"),
                       MapLink(from: nil, to: .coordinate(37.7955, -122.3937), directions: true, transport: .driving))
        XCTAssertEqual(link("https://maps.apple.com/directions?source=Oakland&destination=San+Jose&mode=cycling"),
                       MapLink(from: .address("Oakland"), to: .address("San Jose"), directions: true, transport: .cycling))
        XCTAssertEqual(link("https://maps.apple.com/?ll=51.5007,-0.1246&q=Big%20Ben"),
                       MapLink(from: nil, to: .coordinate(51.5007, -0.1246), name: "Big Ben"))
        XCTAssertEqual(link("https://maps.apple.com/place?coordinate=48.8584,2.2945&name=Eiffel+Tower"),
                       MapLink(from: nil, to: .coordinate(48.8584, 2.2945), name: "Eiffel Tower"))
        XCTAssertEqual(link("https://maps.apple.com/?q=coffee+near+Soho"), MapLink(from: nil, to: .address("coffee near Soho")))
        XCTAssertEqual(link("https://maps.apple.com/search?query=Tate+Modern"), MapLink(from: nil, to: .address("Tate Modern")))
        XCTAssertEqual(link("https://maps.apple.com/?saddr=Current+Location&daddr=Paris")?.from, nil)
        XCTAssertEqual(link("https://maps.apple.com/?ll=95,10")?.to, nil)

        XCTAssertEqual(link("https://maps.apple.com/?saddr=Oakland&daddr=Ferry+Building")?.title, "Directions to Ferry Building")
        XCTAssertEqual(link("https://maps.apple.com/?daddr=37.7955,-122.3937")?.title, "Directions")
        XCTAssertEqual(link("https://maps.apple.com/?ll=51.5007,-0.1246")?.title, "Map")
        XCTAssertEqual(link("https://maps.apple.com/?address=1+Infinite+Loop")?.title, "1 Infinite Loop")

        XCTAssertNil(link("https://maps.apple.com/"))
        XCTAssertNil(link("https://example.com/?daddr=Paris"))
        XCTAssertNil(link("https://maps.google.com/?q=Paris"))
    }

    func testAppleMapsLinkRendersAMapInsteadOfFetchingThePage() async throws {
        let f = loader(); var results: [LinkPreviewMetadataCache.Result] = []
        let url = URL(string: "https://maps.apple.com/?saddr=Oakland&daddr=Ferry+Building")!
        f.cache.load(url) { results.append($0) }
        XCTAssertTrue(f.metadata.isEmpty)
        XCTAssertEqual(f.maps.map(\.0.to), [.address("Ferry Building")])
        let image = NSImage(size: .init(width: 20, height: 20))
        f.maps[0].1(image)
        try await wait { results.count == 1 }
        XCTAssertTrue(results[0].image === image); XCTAssertEqual(f.mapCancellations, 1)
        f.cache.load(url) { results.append($0) }
        XCTAssertTrue(results[1].image === image); XCTAssertEqual(f.maps.count, 1)
    }

    func testMapRenderingIsBoundByTheSameDeadline() async throws {
        let f = loader(); var result: LinkPreviewMetadataCache.Result?
        f.cache.load(URL(string: "https://maps.apple.com/?q=Paris")!, timeout: 5) { result = $0 }
        let deadline = try await f.clock.next(.seconds(5)); deadline.resolve(.success(()))
        try await wait { result != nil }
        XCTAssertNil(result?.image); XCTAssertEqual(f.mapCancellations, 1)
    }

    func testMapCardIsTitledFromItsLinkAndOpensIt() async throws {
        let f = loader(), selection = LinkSelection(); var opened: [URL] = []
        selection.url = URL(string: "https://maps.apple.com/directions?destination=Ferry+Building&mode=walking")!
        selection.visible = true
        let view = host(LinkFixtureView(selection: selection, cache: f.cache, openURL: { opened.append($0) }))
        try await wait { f.maps.count == 1 }
        press(try await control("Open in Maps: Directions to Ferry Building", in: view))
        XCTAssertEqual(opened, [selection.url])
    }
}

@MainActor private struct LinkFixtureView: View {
    let selection: LinkSelection
    let cache: LinkPreviewMetadataCache
    let openURL: (URL) -> Void
    var body: some View { MessageLinkPreview(url: selection.url, shouldLoad: selection.visible, cache: cache, openURL: openURL) }
}
