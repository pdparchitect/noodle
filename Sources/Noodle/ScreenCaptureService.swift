import AppKit
import CoreImage
import ScreenCaptureKit

enum ScreenCaptureKind: String, CaseIterable, Identifiable {
    case screen = "Screens", window = "Windows"
    var id: Self { self }
}

struct ScreenCaptureSource: Identifiable, Equatable, Sendable {
    enum ID: Hashable, Sendable { case screen(CGDirectDisplayID), window(CGWindowID) }
    let id: ID
    let title: String
    let subtitle: String
    var displayID: CGDirectDisplayID? = nil
    var frame: CGRect = .zero
    var isOnScreen = true
    var fillsDisplay = false

    func priority(on currentDisplay: CGDirectDisplayID?) -> Int {
        if isOnScreen, let currentDisplay, displayID == currentDisplay { return 0 }
        return fillsDisplay ? 2 : 1
    }

    static func display(for frame: CGRect, among displays: [(id: CGDirectDisplayID, frame: CGRect)]) -> CGDirectDisplayID? {
        displays.filter { $0.frame.intersects(frame) }.max {
            let a = $0.frame.intersection(frame), b = $1.frame.intersection(frame)
            return a.width * a.height < b.width * b.height
        }?.id
    }

    static func fillsDisplay(_ frame: CGRect, display: CGRect) -> Bool {
        abs(frame.minX - display.minX) <= 2 && abs(frame.minY - display.minY) <= 2 &&
            abs(frame.width - display.width) <= 2 && abs(frame.height - display.height) <= 2
    }

    static func ordered(_ sources: [Self], on currentDisplay: CGDirectDisplayID? = nil) -> [Self] {
        var seen = Set<ID>()
        return sources.filter { seen.insert($0.id).inserted }.sorted { lhs, rhs in
            let leftPriority = lhs.priority(on: currentDisplay), rightPriority = rhs.priority(on: currentDisplay)
            if leftPriority != rightPriority { return leftPriority < rightPriority }
            let leftArea = lhs.frame.width * lhs.frame.height, rightArea = rhs.frame.width * rhs.frame.height
            if leftArea != rightArea { return leftArea > rightArea }
            let left: [String], right: [String]
            switch (lhs.id, rhs.id) {
            case (.window, .window):
                left = [lhs.subtitle, lhs.title]; right = [rhs.subtitle, rhs.title]
            default:
                left = [lhs.title, lhs.subtitle]; right = [rhs.title, rhs.subtitle]
            }
            for (a, b) in zip(left, right) {
                let order = a.localizedStandardCompare(b)
                if order != .orderedSame { return order == .orderedAscending }
            }
            // Stable ties keep distinct windows with identical names selectable.
            switch (lhs.id, rhs.id) {
            case (.screen(let a), .screen(let b)), (.window(let a), .window(let b)): return a < b
            case (.screen, .window): return true
            case (.window, .screen): return false
            }
        }
    }
}

enum ScreenCaptureThumbnail {
    /// Helper windows can return a successful but transparent image, sometimes
    /// with only a thin line. Check alpha coverage, preserving solid black/white
    /// windows and other low-contrast content that is still useful to capture.
    static func hasContent(_ image: CGImage) -> Bool {
        guard image.width >= 8, image.height >= 8 else { return false }
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: side, height: side,
                bitsPerComponent: 8, bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            var count = 0, minX = side, minY = side, maxX = -1, maxY = -1
            for y in 0..<side {
                for x in 0..<side where bytes[(y * side + x) * 4 + 3] >= 32 {
                    count += 1
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            return count >= side * side / 100 && maxX - minX >= 3 && maxY - minY >= 3
        }
    }
}

struct ScreenCaptureFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum ScreenCaptureFrame: Sendable {
    case image(CGImage)
    case paused
}

@MainActor protocol ScreenCaptureFeed: AnyObject {
    var frames: AsyncThrowingStream<ScreenCaptureFrame, Error> { get }
    func start() async throws
    func stop() async
}

@MainActor enum ScreenCaptureProbe {
    /// A thumbnail must come from a working live stream and survive a brief
    /// settling period. Static windows need no second frame; a pause resets it.
    static func capture(_ feed: any ScreenCaptureFeed, timeout: Duration = .seconds(3),
                        settling: Duration = .milliseconds(150)) async throws -> CGImage {
        var image: CGImage?, validated = false
        var settle: Task<Void, Never>?
        let deadline = Task { @MainActor in
            do { try await Task.sleep(for: timeout) } catch { return }
            await feed.stop()
        }
        defer { deadline.cancel(); settle?.cancel() }
        return try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                try await feed.start()
                try Task.checkCancellation()
                for try await frame in feed.frames {
                    switch frame {
                    case .paused:
                        image = nil; settle?.cancel(); settle = nil
                    case .image(let next):
                        guard ScreenCaptureThumbnail.hasContent(next) else {
                            throw ScreenCaptureFailure(message: "This window has no visible content.")
                        }
                        image = next
                        if settle == nil {
                            settle = Task { @MainActor in
                                do { try await Task.sleep(for: settling) } catch { return }
                                validated = true
                                await feed.stop()
                            }
                        }
                    }
                }
                try Task.checkCancellation()
                await feed.stop()
                guard validated, let image else { throw ScreenCaptureFailure(message: "This source cannot provide a live preview.") }
                return image
            } catch {
                await feed.stop()
                throw error
            }
        } onCancel: {
            Task { @MainActor in await feed.stop() }
        }
    }
}

@MainActor protocol ScreenCaptureProviding {
    var hasPermission: Bool { get }
    func requestPermission()
    func sources(kind: ScreenCaptureKind, excluding: [CGWindowID]) async throws -> [ScreenCaptureSource]
    func thumbnail(for source: ScreenCaptureSource, excluding: [CGWindowID]) async throws -> CGImage
    func feed(for source: ScreenCaptureSource, excluding: [CGWindowID]) async throws -> any ScreenCaptureFeed
}

/// All pixels stay inside the sandboxed app. Only the selected source gets a
/// full-resolution stream; picker checks briefly open small streams, four at a time.
@MainActor final class ScreenCaptureService: ScreenCaptureProviding {
    private var thumbnailContent: SCShareableContent?
    var hasPermission: Bool { CGPreflightScreenCaptureAccess() }
    func requestPermission() { CGRequestScreenCaptureAccess() }

    func sources(kind: ScreenCaptureKind, excluding: [CGWindowID]) async throws -> [ScreenCaptureSource] {
        // Include inactive Spaces and full-screen apps on every display. A
        // desktop-independent window filter can capture these without switching Spaces.
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        return sources(kind: kind, excluding: excluding, in: content)
    }

    /// Also accepts a current-process snapshot for sandboxed picker checks.
    func sources(kind: ScreenCaptureKind, excluding: [CGWindowID], in content: SCShareableContent) -> [ScreenCaptureSource] {
        thumbnailContent = content
        switch kind {
        case .screen:
            return content.displays.map { display in
                let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID }
                return ScreenCaptureSource(id: .screen(display.displayID), title: screen?.localizedName ?? "Display \(display.displayID)",
                    subtitle: "\(display.width) × \(display.height)", displayID: display.displayID, frame: display.frame)
            }
        case .window:
            return content.windows.filter {
                !excluding.contains($0.windowID) && $0.windowLayer == 0 &&
                    $0.frame.width >= 40 && $0.frame.height >= 40 && $0.owningApplication != nil
            }.map { window in
                let app = window.owningApplication?.applicationName ?? "Application"
                let title = window.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                let displays = content.displays.map { (id: $0.displayID, frame: $0.frame) }
                let displayID = ScreenCaptureSource.display(for: window.frame, among: displays)
                let fillsDisplay = displays.contains { ScreenCaptureSource.fillsDisplay(window.frame, display: $0.frame) }
                return ScreenCaptureSource(id: .window(window.windowID), title: title?.isEmpty == false ? title! : app,
                    subtitle: app, displayID: displayID, frame: window.frame, isOnScreen: window.isOnScreen, fillsDisplay: fillsDisplay)
            }
        }
    }

    private func filter(for source: ScreenCaptureSource, excluding: [CGWindowID]) async throws -> SCContentFilter {
        // Resolve IDs again: windows may close or move to another Space after selection.
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        return try filter(for: source, excluding: excluding, in: content)
    }

    private func filter(for source: ScreenCaptureSource, excluding: [CGWindowID], in content: SCShareableContent) throws -> SCContentFilter {
        switch source.id {
        case .screen(let id):
            guard let display = content.displays.first(where: { $0.displayID == id }) else {
                throw ScreenCaptureFailure(message: "This screen is no longer connected. Choose another source.")
            }
            return SCContentFilter(display: display, excludingWindows: content.windows.filter { excluding.contains($0.windowID) })
        case .window(let id):
            guard !excluding.contains(id), let window = content.windows.first(where: { $0.windowID == id }) else {
                throw ScreenCaptureFailure(message: "This window is no longer available. Reopen it or choose another source.")
            }
            return SCContentFilter(desktopIndependentWindow: window)
        }
    }

    private func configuration(for filter: SCContentFilter, thumbnail: Bool) -> SCStreamConfiguration {
        let configuration = SCStreamConfiguration()
        let rect = filter.contentRect
        let scale = thumbnail ? min(1, 440 / max(1, rect.width), 280 / max(1, rect.height)) : CGFloat(filter.pointPixelScale)
        configuration.width = max(1, Int((rect.width * scale).rounded()))
        configuration.height = max(1, Int((rect.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.includeChildWindows = false
        configuration.captureResolution = .best
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.capturesAudio = false
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB
        return configuration
    }

    func thumbnail(for source: ScreenCaptureSource, excluding: [CGWindowID]) async throws -> CGImage {
        // Reuse the picker snapshot instead of enumerating every app and window
        // again for each thumbnail. Starting a live feed still resolves fresh IDs.
        let filter: SCContentFilter
        if let content = thumbnailContent { filter = try self.filter(for: source, excluding: excluding, in: content) }
        else { filter = try await self.filter(for: source, excluding: excluding) }
        try Task.checkCancellation()
        return try await ScreenCaptureProbe.capture(CaptureStream(filter: filter, configuration: configuration(for: filter, thumbnail: true)))
    }

    func feed(for source: ScreenCaptureSource, excluding: [CGWindowID]) async throws -> any ScreenCaptureFeed {
        let filter = try await filter(for: source, excluding: excluding)
        try Task.checkCancellation()
        return feed(filter: filter)
    }

    /// Also accepts a current-process filter for sandboxed native capture checks.
    func feed(filter: SCContentFilter) -> any ScreenCaptureFeed {
        CaptureStream(filter: filter, configuration: configuration(for: filter, thumbnail: false))
    }
}

@MainActor private final class CaptureStream: ScreenCaptureFeed {
    let frames: AsyncThrowingStream<ScreenCaptureFrame, Error>
    private let output: CaptureStreamOutput
    private let stream: SCStream

    init(filter: SCContentFilter, configuration: SCStreamConfiguration) {
        let pair = AsyncThrowingStream<ScreenCaptureFrame, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        frames = pair.stream
        output = CaptureStreamOutput(continuation: pair.continuation)
        stream = SCStream(filter: filter, configuration: configuration, delegate: output)
    }
    func start() async throws {
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
        try await stream.startCapture()
    }
    func stop() async {
        output.continuation.finish()
        try? await stream.stopCapture()
        try? stream.removeStreamOutput(output, type: .screen)
    }
}

final class CaptureStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.pdparchitect.noodle.capture", qos: .userInitiated)
    let continuation: AsyncThrowingStream<ScreenCaptureFrame, Error>.Continuation
    private let context = CIContext(options: [.cacheIntermediates: false])
    init(continuation: AsyncThrowingStream<ScreenCaptureFrame, Error>.Continuation) { self.continuation = continuation }

    func stream(_ stream: SCStream, didStopWithError error: Error) { continuation.finish(throwing: error) }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        process(sampleBuffer)
    }
    func process(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus) else { return }
        if status == .stopped {
            continuation.finish(throwing: ScreenCaptureFailure(message: "The source stopped providing images. Retake or choose another source."))
            return
        }
        if status == .blank || status == .suspended {
            continuation.yield(.paused)
            return
        }
        guard status == .complete || status == .started, let buffer = sampleBuffer.imageBuffer else { return }
        let image = CIImage(cvPixelBuffer: buffer)
        if let frame = context.createCGImage(image, from: image.extent) { continuation.yield(.image(frame)) }
    }
}
