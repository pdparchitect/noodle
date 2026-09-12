import AppKit
import XCTest
import ScreenCaptureKit
import NoodleCore
@testable import Noodle

@MainActor final class ScreenCaptureTests: XCTestCase {
    private let source = ScreenCaptureSource(id: .screen(1), title: "Test Display", subtitle: "640 × 480")
    private func image(_ color: NSColor = .blue) -> CGImage {
        let context = CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(color.cgColor); context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        return context.makeImage()!
    }
    private func until(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Capture state did not settle", file: file, line: line)
    }

    func testPlainCaptureSavesDisplayedFrameWithoutAnnotation() async {
        let service = CaptureTestService()
        let model = ScreenCaptureModel(kind: .screen, service: service)
        var saved: CGImage?
        var finished = false
        model.onSave = { frame, title, region, comment in
            saved = frame; XCTAssertEqual(title, self.source.title)
            XCTAssertNil(region); XCTAssertEqual(comment, "")
        }
        model.onFinish = { finished = true }
        model.select(source)
        XCTAssertFalse(model.canCapture)
        await until { service.feeds.first?.started == true }
        let frame = image()
        service.feeds[0].send(frame)
        await until { model.canCapture }
        model.capture()
        XCTAssertTrue(saved === frame); XCTAssertTrue(finished); XCTAssertEqual(model.phase, .closed)
        await until { service.feeds[0].stops == 1 }
    }

    func testAnnotationFreezesFrameAndRetakeIgnoresOldFrames() async {
        let service = CaptureTestService()
        let model = ScreenCaptureModel(kind: .window, service: service)
        model.select(source)
        await until { service.feeds.first?.started == true }
        let first = image(.blue), next = image(.green)
        service.feeds[0].send(first)
        await until { model.canCapture }
        model.annotate()
        service.feeds[0].send(next)
        await until { service.feeds[0].stops == 1 }
        XCTAssertTrue(model.image === first); XCTAssertEqual(model.phase, .annotating)
        XCTAssertFalse(model.canCapture); XCTAssertFalse(model.canSaveAnnotation)
        model.region = .init(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
        model.comment = "Move this detail"
        XCTAssertTrue(model.canSaveAnnotation)
        model.retake()
        XCTAssertNil(model.region); XCTAssertTrue(model.comment.isEmpty); XCTAssertNil(model.image)
        await until { service.feeds.count == 2 && service.feeds[1].started }
        service.feeds[1].send(next)
        await until { model.canCapture }
        XCTAssertTrue(model.image === next)
        model.close()
        await until { service.feeds[1].stops == 1 }
    }

    func testCloseDuringStartupStopsLateStreamWithoutPublishing() async {
        let service = CaptureTestService(); service.delayStart = true
        let model = ScreenCaptureModel(kind: .screen, service: service)
        model.select(source)
        await until { service.feeds.first?.startWaiter != nil }
        model.close()
        service.feeds[0].startWaiter?.resume(); service.feeds[0].startWaiter = nil
        service.feeds[0].send(image())
        await until { service.feeds[0].stops == 1 }
        XCTAssertEqual(model.phase, .closed); XCTAssertNil(model.image)
    }

    func testSwitchingSourcesRejectsLateStartupAndFrames() async {
        let service = CaptureTestService(); service.delayStart = true
        let model = ScreenCaptureModel(kind: .screen, service: service)
        model.select(source)
        await until { service.feeds.first?.startWaiter != nil }
        service.delayStart = false
        let other = ScreenCaptureSource(id: .window(12), title: "Other Window", subtitle: "Test")
        model.select(other)
        await until { service.feeds.count == 2 && service.feeds[1].started }
        let expected = image(.green)
        service.feeds[1].send(expected)
        await until { model.canCapture }
        service.feeds[0].startWaiter?.resume(); service.feeds[0].startWaiter = nil
        service.feeds[0].send(image(.red))
        await until { service.feeds[0].stops == 1 }
        XCTAssertEqual(model.source, other); XCTAssertTrue(model.image === expected)
        model.close()
    }

    func testCaptureFailureRemovesSourceUntilExplicitRefresh() async {
        let other = ScreenCaptureSource(id: .window(22), title: "Usable", subtitle: "App")
        let service = CaptureTestService(); service.list = [source, other]; service.preview = image()
        let model = ScreenCaptureModel(kind: .screen, service: service)
        model.select(source)
        await until { service.feeds.first?.started == true }
        service.feeds[0].send(image())
        await until { model.canCapture }
        service.feeds[0].continuation.finish(throwing: ScreenCaptureFailure(message: "Window closed"))
        await until { model.phase == .choosing && !model.loadingSources }
        XCTAssertNil(model.image); XCTAssertFalse(model.canCapture)
        XCTAssertEqual(model.sources, [other]); XCTAssertTrue(model.error?.contains("removed") == true)
        model.chooseSources()
        await until { !model.loadingSources }
        XCTAssertEqual(model.sources, [other])
        model.chooseSources(retryUnavailable: true)
        await until { !model.loadingSources }
        XCTAssertEqual(Set(model.sources.map(\.id)), Set([source.id, other.id]))
        model.close()
    }

    func testTemporaryPauseDisablesCaptureAndRecoversOnSameFeed() async {
        let service = CaptureTestService()
        let model = ScreenCaptureModel(kind: .window, service: service)
        model.select(source)
        await until { service.feeds.first?.started == true }
        let feed = service.feeds[0]
        feed.send(image())
        await until { model.canCapture }
        feed.continuation.yield(.paused)
        await until { model.phase == .loading }
        XCTAssertNil(model.image); XCTAssertFalse(model.canCapture); XCTAssertNil(model.error)
        let recovered = image(.green)
        feed.send(recovered)
        await until { model.canCapture }
        XCTAssertTrue(model.image === recovered); XCTAssertEqual(service.feeds.count, 1)
        model.close()
    }

    func testProbeAcceptsStaticLiveFrameAndStopsItsFeed() async throws {
        let feed = CaptureTestFeed()
        let task = Task { try await ScreenCaptureProbe.capture(feed, timeout: .seconds(1), settling: .milliseconds(10)) }
        await until { feed.started }
        let expected = image(.black)
        feed.send(expected)
        let result = try await task.value
        XCTAssertTrue(result === expected); XCTAssertGreaterThanOrEqual(feed.stops, 1)
    }

    func testProbeRecoversFromInitialPause() async throws {
        let feed = CaptureTestFeed()
        let task = Task { try await ScreenCaptureProbe.capture(feed, timeout: .seconds(1), settling: .milliseconds(10)) }
        await until { feed.started }
        feed.continuation.yield(.paused)
        try await Task.sleep(for: .milliseconds(10))
        feed.send(image(.white))
        _ = try await task.value
        XCTAssertGreaterThanOrEqual(feed.stops, 1)
    }

    func testProbeRejectsThumbnailThatCannotStayLive() async {
        let feed = CaptureTestFeed()
        let task = Task { try await ScreenCaptureProbe.capture(feed, timeout: .milliseconds(100), settling: .milliseconds(60)) }
        await until { feed.started }
        feed.send(image())
        try? await Task.sleep(for: .milliseconds(20))
        feed.continuation.yield(.paused)
        do { _ = try await task.value; XCTFail("A suspended source must not produce a picker tile") } catch {}
        XCTAssertGreaterThanOrEqual(feed.stops, 1)
    }

    func testProbeStopsWhenNoFramesArrive() async {
        let feed = CaptureTestFeed()
        do {
            _ = try await ScreenCaptureProbe.capture(feed, timeout: .milliseconds(20))
            XCTFail("An empty stream must not produce a picker tile")
        } catch {}
        XCTAssertGreaterThanOrEqual(feed.stops, 1)
    }

    func testProbeCancellationStopsLateStartup() async {
        let feed = CaptureTestFeed(); feed.delayStart = true
        let task = Task { try await ScreenCaptureProbe.capture(feed) }
        await until { feed.startWaiter != nil }
        task.cancel()
        await until { feed.stops > 0 }
        feed.startWaiter?.resume(); feed.startWaiter = nil
        do { _ = try await task.value; XCTFail("A cancelled probe must not publish an image") } catch {}
        XCTAssertGreaterThanOrEqual(feed.stops, 2)
    }

    func testRealStreamStatusesPauseRecoverAndAcceptStartedImages() async throws {
        let pair = AsyncThrowingStream<ScreenCaptureFrame, Error>.makeStream()
        let output = CaptureStreamOutput(continuation: pair.continuation)
        var pixelBuffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 32, 32, kCVPixelFormatType_32BGRA, nil, &pixelBuffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(pixelBuffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        memset(CVPixelBufferGetBaseAddress(pixels), 255, CVPixelBufferGetBytesPerRow(pixels) * 32)
        CVPixelBufferUnlockBaseAddress(pixels, [])
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &format), noErr)
        for status in [SCFrameStatus.blank, .started, .idle, .suspended, .complete] {
            var sample: CMSampleBuffer?
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
            XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels,
                formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
            let buffer = try XCTUnwrap(sample)
            let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true)! as NSArray
            (attachments[0] as! NSMutableDictionary)[SCStreamFrameInfo.status] = status.rawValue
            output.process(buffer)
        }
        pair.continuation.finish()
        var events: [String] = []
        for try await event in pair.stream {
            switch event { case .paused: events.append("paused"); case .image: events.append("image") }
        }
        XCTAssertEqual(events, ["paused", "image", "paused", "image"])
    }

    func testFailedAnnotationSavePreservesDraftAndFrozenFrame() async {
        let service = CaptureTestService()
        let model = ScreenCaptureModel(kind: .screen, service: service)
        model.select(source)
        await until { service.feeds.first?.started == true }
        let frame = image()
        service.feeds[0].send(frame)
        await until { model.canCapture }
        model.annotate(); model.region = .init(x: 0, y: 0, width: 1, height: 1); model.comment = "Keep this"
        model.onSave = { _, _, _, _ in throw ScreenCaptureFailure(message: "Disk is full") }
        model.onFinish = { XCTFail("Failed saves must stay open") }
        model.saveAnnotation()
        XCTAssertEqual(model.phase, .annotating); XCTAssertTrue(model.image === frame)
        XCTAssertEqual(model.comment, "Keep this"); XCTAssertEqual(model.error, "Disk is full")
        model.onSave = { image, _, region, comment in
            XCTAssertTrue(image === frame); XCTAssertEqual(region?.width, 1); XCTAssertEqual(comment, "Keep this")
        }
        model.onFinish = nil
        model.saveAnnotation()
        XCTAssertEqual(model.phase, .closed)
    }

    func testPermissionIsRequestedOnlyByExplicitAction() async {
        let service = CaptureTestService(); service.hasPermission = false
        let model = ScreenCaptureModel(kind: .screen, service: service)
        model.chooseSources()
        XCTAssertTrue(model.needsPermission); XCTAssertEqual(service.sourceRequests, 0); XCTAssertEqual(service.permissionRequests, 0)
        model.permissionMayHaveChanged()
        XCTAssertEqual(service.permissionRequests, 0)
        model.requestPermission()
        await until { service.sourceRequests == 1 && !model.loadingSources }
        XCTAssertEqual(service.permissionRequests, 1); XCTAssertFalse(model.needsPermission)
        model.close()
    }

    func testExcludedPickerWindowsReachDiscoveryThumbnailsAndStream() async {
        let service = CaptureTestService(); service.list = [source]; service.preview = image()
        let model = ScreenCaptureModel(kind: .screen, service: service, excludedWindows: { [17, 23] })
        model.chooseSources()
        await until { model.thumbnails.count == 1 }
        model.select(source)
        await until { service.feeds.first?.started == true }
        XCTAssertEqual(service.exclusions, [[17, 23], [17, 23], [17, 23]])
        model.close()
    }

    private func transparentImage(mark: CGRect? = nil) -> CGImage {
        let context = CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if let mark { context.setFillColor(NSColor.black.cgColor); context.fill(mark) }
        return context.makeImage()!
    }

    func testThumbnailRejectsTransparentHelpersAndSliversWithoutRejectingSolidContent() {
        XCTAssertFalse(ScreenCaptureThumbnail.hasContent(transparentImage()))
        XCTAssertFalse(ScreenCaptureThumbnail.hasContent(transparentImage(mark: CGRect(x: 320, y: 0, width: 2, height: 480))))
        XCTAssertFalse(ScreenCaptureThumbnail.hasContent(transparentImage(mark: CGRect(x: 0, y: 240, width: 640, height: 2))))
        XCTAssertFalse(ScreenCaptureThumbnail.hasContent(transparentImage(mark: CGRect(x: 320, y: 240, width: 4, height: 4))))
        XCTAssertTrue(ScreenCaptureThumbnail.hasContent(transparentImage(mark: CGRect(x: 40, y: 40, width: 560, height: 400))))
        XCTAssertTrue(ScreenCaptureThumbnail.hasContent(image(.black)))
        XCTAssertTrue(ScreenCaptureThumbnail.hasContent(image(.white)))
    }

    func testPickerFiltersDudsAndSortsByAppThenNaturalTitleWithStableTies() async {
        let a = ScreenCaptureSource(id: .window(1), title: "Window 2", subtitle: "Alpha")
        let sameTitle = ScreenCaptureSource(id: .window(2), title: a.title, subtitle: a.subtitle)
        let b = ScreenCaptureSource(id: .window(3), title: "Window 10", subtitle: "Alpha")
        let c = ScreenCaptureSource(id: .window(4), title: "Window 1", subtitle: "Beta")
        let blank = ScreenCaptureSource(id: .window(5), title: "AutoFill", subtitle: "Alpha")
        let failed = ScreenCaptureSource(id: .window(6), title: "Unavailable", subtitle: "Alpha")
        let strip = ScreenCaptureSource(id: .window(7), title: "Helper", subtitle: "Alpha")
        let service = CaptureTestService()
        service.list = [c, b, blank, a, sameTitle, failed, strip, a]
        service.previews = [a.id: image(.white), sameTitle.id: image(.black), b.id: image(), c.id: image(),
            blank.id: transparentImage(), strip.id: transparentImage(mark: CGRect(x: 0, y: 240, width: 640, height: 2))]
        let model = ScreenCaptureModel(kind: .window, service: service)
        model.chooseSources()
        await until { !model.loadingSources }
        XCTAssertEqual(model.sources, [a, sameTitle, b, c])
        XCTAssertEqual(Set(model.thumbnails.keys), Set([a.id, sameTitle.id, b.id, c.id]))
        model.close()
    }

    func testScreenPickerSortsDisplayNamesNaturally() async {
        let a = ScreenCaptureSource(id: .screen(3), title: "Display 2", subtitle: "640 × 480")
        let b = ScreenCaptureSource(id: .screen(1), title: "Display 10", subtitle: "640 × 480")
        let service = CaptureTestService(); service.list = [b, a]; service.preview = image(.black)
        let model = ScreenCaptureModel(kind: .screen, service: service)
        model.chooseSources()
        await until { !model.loadingSources }
        XCTAssertEqual(model.sources, [a, b])
        model.close()
    }

    func testPickerPrioritizesCurrentDisplayThenDesktopThenFullScreenAndArea() {
        func window(_ id: UInt32, _ size: CGFloat, display: UInt32, visible: Bool = true, full: Bool = false) -> ScreenCaptureSource {
            ScreenCaptureSource(id: .window(id), title: "Window \(id)", subtitle: "App", displayID: display,
                frame: CGRect(x: 0, y: 0, width: size, height: size), isOnScreen: visible, fillsDisplay: full)
        }
        let smallHere = window(1, 200, display: 10), largeHere = window(2, 700, display: 10)
        let elsewhere = window(3, 1_000, display: 20), smallElsewhere = window(4, 300, display: 20)
        let otherSpace = window(5, 800, display: 10, visible: false)
        let fullScreen = window(6, 2_000, display: 10, visible: false, full: true)
        let otherFullScreen = window(7, 1_800, display: 20, full: true)
        XCTAssertEqual(ScreenCaptureSource.ordered([fullScreen, smallHere, elsewhere, otherFullScreen, otherSpace, largeHere, smallElsewhere], on: 10),
            [largeHere, smallHere, elsewhere, otherSpace, smallElsewhere, fullScreen, otherFullScreen])
        XCTAssertEqual(ScreenCaptureSource.ordered([smallHere, elsewhere], on: 20), [elsewhere, smallHere])
    }

    func testDisplayAssociationUsesWindowServerCoordinatesAndLargestOverlap() {
        let primary = CGRect(x: 0, y: 0, width: 1_440, height: 900)
        let above = CGRect(x: 0, y: -1_080, width: 1_920, height: 1_080)
        let displays: [(id: CGDirectDisplayID, frame: CGRect)] = [(10, primary), (20, above)]
        XCTAssertEqual(ScreenCaptureSource.display(for: CGRect(x: 100, y: -400, width: 600, height: 450), among: displays), 20)
        XCTAssertEqual(ScreenCaptureSource.display(for: CGRect(x: 100, y: 100, width: 600, height: 450), among: displays), 10)
        XCTAssertTrue(ScreenCaptureSource.fillsDisplay(above, display: above))
        XCTAssertFalse(ScreenCaptureSource.fillsDisplay(above.insetBy(dx: 10, dy: 10), display: above))
    }

    func testPendingThumbnailsNeverBecomeTilesOrReorderCompletedTiles() async {
        let a = ScreenCaptureSource(id: .window(1), title: "A", subtitle: "App")
        let b = ScreenCaptureSource(id: .window(2), title: "B", subtitle: "App")
        let c = ScreenCaptureSource(id: .window(3), title: "C", subtitle: "App")
        let service = CaptureTestService(); service.list = [c, b, a]; service.delayThumbnails = true
        let model = ScreenCaptureModel(kind: .window, service: service)
        model.chooseSources()
        await until { service.thumbnailWaiters.count == 3 }
        XCTAssertTrue(model.sources.isEmpty)
        service.thumbnailWaiters.removeValue(forKey: b.id)?.resume(returning: image())
        await until { service.activeThumbnails == 2 }
        XCTAssertTrue(model.sources.isEmpty)
        service.thumbnailWaiters.removeValue(forKey: a.id)?.resume(throwing: ScreenCaptureFailure(message: "Closed"))
        await until { model.sources == [b] }
        XCTAssertTrue(model.loadingSources)
        service.thumbnailWaiters.removeValue(forKey: c.id)?.resume(returning: image())
        await until { !model.loadingSources }
        XCTAssertEqual(model.sources, [b, c])
        model.close()
    }

    func testPickerRefreshRejectsLateThumbnailsFromPreviousTab() async {
        let a = ScreenCaptureSource(id: .window(1), title: "Old Window", subtitle: "App")
        let b = ScreenCaptureSource(id: .screen(2), title: "New Screen", subtitle: "640 × 480")
        let service = CaptureTestService(); service.list = [a]; service.delayThumbnails = true
        let model = ScreenCaptureModel(kind: .window, service: service)
        model.chooseSources()
        await until { service.thumbnailWaiters[a.id] != nil }
        model.kind = .screen; service.list = [b]; model.chooseSources()
        await until { service.thumbnailWaiters[b.id] != nil }
        service.thumbnailWaiters.removeValue(forKey: b.id)?.resume(returning: image())
        await until { !model.loadingSources }
        service.thumbnailWaiters.removeValue(forKey: a.id)?.resume(returning: image())
        await until { service.activeThumbnails == 0 }
        XCTAssertEqual(model.sources, [b]); XCTAssertEqual(Set(model.thumbnails.keys), Set([b.id]))
        model.close()
    }

    func testPickerBoundsThumbnailWorkAndCloseDiscardsPendingResults() async {
        let service = CaptureTestService(); service.delayThumbnails = true
        service.list = (1...12).map { ScreenCaptureSource(id: .window(UInt32($0)), title: "Window \($0)", subtitle: "App") }
        let model = ScreenCaptureModel(kind: .window, service: service)
        model.chooseSources()
        await until { service.thumbnailWaiters.count == 4 }
        let first = service.thumbnailWaiters.keys.first!
        service.thumbnailWaiters.removeValue(forKey: first)?.resume(returning: image())
        await until { service.thumbnailRequests == 5 }
        XCTAssertEqual(service.peakThumbnails, 4)
        model.close()
        for waiter in service.thumbnailWaiters.values { waiter.resume(returning: image()) }
        service.thumbnailWaiters.removeAll()
        await until { service.activeThumbnails == 0 }
        XCTAssertEqual(service.thumbnailRequests, 5)
        XCTAssertTrue(model.sources.isEmpty); XCTAssertTrue(model.thumbnails.isEmpty); XCTAssertEqual(model.phase, .closed)
    }

    func testSelectionCoordinatesExcludeLetterboxingAndSurviveResize() {
        let fit = ScreenCaptureCanvas.imageRect(imageSize: CGSize(width: 1920, height: 1080), bounds: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(fit, CGRect(x: 0, y: 75, width: 800, height: 450))
        let region = ScreenCaptureCanvas.normalizedRegion(CGRect(x: 200, y: 187.5, width: 400, height: 225), in: fit)
        XCTAssertEqual(region, .init(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        let resized = ScreenCaptureCanvas.imageRect(imageSize: CGSize(width: 3840, height: 2160), bounds: CGRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertEqual(ScreenCaptureCanvas.normalizedRegion(CGRect(x: 100, y: 93.75, width: 200, height: 112.5), in: resized), region)
        XCTAssertNil(ScreenCaptureCanvas.normalizedRegion(CGRect(x: 0, y: 0, width: 40, height: 20), in: fit))
        XCTAssertEqual(ScreenCaptureCanvas.normalizedRegion(CGRect(x: -20, y: 0, width: 1000, height: 800), in: fit),
                       .init(x: 0, y: 0, width: 1, height: 1))
    }

    func testPNGAndAnnotatedCapturePersistToOriginWithoutSending() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("capture-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = WorkspaceRepository(rootURL: directory)
        try repository.prepare()
        let first = try repository.createAgent(named: "First"), second = try repository.createAgent(named: "Second")
        let plain = try CaptureAttachment.save(image: image(), title: "Example / Window", region: nil, comment: "",
            into: first.conversation.id, repository: repository)
        XCTAssertNil(plain.source); XCTAssertNil(plain.attachment.annotation)
        XCTAssertEqual(plain.attachment.mediaType, "image/png")
        let png = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: repository.attachmentFileURL(plain.attachment))))
        XCTAssertEqual(png.pixelsWide, 640); XCTAssertEqual(png.pixelsHigh, 480)
        let marked = try CaptureAttachment.save(image: image(), title: "Example", region: .init(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
            comment: "Move this", into: first.conversation.id, repository: repository)
        let source = try XCTUnwrap(marked.source)
        XCTAssertEqual(marked.attachment.annotation?.sourceAttachmentID, source.id)
        XCTAssertEqual(marked.attachment.annotation?.comment, "Move this")
        let savedImage = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: repository.attachmentFileURL(marked.attachment))))
        XCTAssertEqual(savedImage.pixelsWide, 640); XCTAssertEqual(savedImage.pixelsHigh, 480)
        let edge = try XCTUnwrap(savedImage.colorAt(x: 160, y: 240)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(edge.redComponent, 0.9); XCTAssertLessThan(edge.blueComponent, 0.1)
        XCTAssertTrue(try repository.loadAttachments(conversationID: second.conversation.id).isEmpty)
        XCTAssertTrue(try repository.latestMessages(for: first.agent.id, consuming: false).isEmpty)
        var drafts = ConversationDrafts()
        drafts.restoreAnnotations(try repository.loadAttachments(conversationID: first.conversation.id), messages: [], conversationID: first.conversation.id)
        XCTAssertEqual(drafts[first.conversation.id].attachments.map(\.id), [marked.attachment.id], "Recover the annotation without adding its original as another draft attachment")
        let before = try repository.loadAttachments(conversationID: first.conversation.id)
        XCTAssertThrowsError(try CaptureAttachment.save(image: image(), title: "Invalid", region: .init(x: 0, y: 0, width: 1, height: 1),
            comment: "  ", into: first.conversation.id, repository: repository))
        XCTAssertEqual(try repository.loadAttachments(conversationID: first.conversation.id), before)
    }
}

@MainActor private final class CaptureTestService: ScreenCaptureProviding {
    var hasPermission = true
    var permissionRequests = 0
    var sourceRequests = 0
    var delayStart = false
    var list: [ScreenCaptureSource] = []
    var preview: CGImage?
    var previews: [ScreenCaptureSource.ID: CGImage] = [:]
    var delayThumbnails = false
    var thumbnailWaiters: [ScreenCaptureSource.ID: CheckedContinuation<CGImage, Error>] = [:]
    var thumbnailRequests = 0
    var activeThumbnails = 0
    var peakThumbnails = 0
    var feeds: [CaptureTestFeed] = []
    var exclusions: [[CGWindowID]] = []
    func requestPermission() { permissionRequests += 1; hasPermission = true }
    func sources(kind: ScreenCaptureKind, excluding: [CGWindowID]) async throws -> [ScreenCaptureSource] {
        sourceRequests += 1; exclusions.append(excluding); return list
    }
    func thumbnail(for source: ScreenCaptureSource, excluding: [CGWindowID]) async throws -> CGImage {
        exclusions.append(excluding)
        thumbnailRequests += 1; activeThumbnails += 1; peakThumbnails = max(peakThumbnails, activeThumbnails)
        defer { activeThumbnails -= 1 }
        if delayThumbnails { return try await withCheckedThrowingContinuation { thumbnailWaiters[source.id] = $0 } }
        guard let preview = previews[source.id] ?? preview else { throw ScreenCaptureFailure(message: "No thumbnail") }
        return preview
    }
    func feed(for source: ScreenCaptureSource, excluding: [CGWindowID]) async throws -> any ScreenCaptureFeed {
        exclusions.append(excluding)
        let feed = CaptureTestFeed(); feed.delayStart = delayStart; feeds.append(feed); return feed
    }
}

@MainActor private final class CaptureTestFeed: ScreenCaptureFeed {
    let frames: AsyncThrowingStream<ScreenCaptureFrame, Error>
    let continuation: AsyncThrowingStream<ScreenCaptureFrame, Error>.Continuation
    var delayStart = false
    var started = false
    var stops = 0
    var startWaiter: CheckedContinuation<Void, Never>?
    init() {
        let pair = AsyncThrowingStream<ScreenCaptureFrame, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        frames = pair.stream; continuation = pair.continuation
    }
    func send(_ image: CGImage) { continuation.yield(.image(image)) }
    func start() async throws {
        if delayStart { await withCheckedContinuation { startWaiter = $0 } }
        started = true
    }
    func stop() async { stops += 1; continuation.finish() }
}
