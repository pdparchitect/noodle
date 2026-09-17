import AppKit
import CoreImage
import CoreMedia
import LocalMacCore
import LocalMacPrivate
import ScreenCaptureKit

/// A second display-bound stream preserves child-window composition. Only its
/// nontransparent content is encoded; the ordinary desktop stream stays intact.
@MainActor final class AccountWindowCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let session: LocalMacSession
    let desktop: AccountCapture
    let output: Output
    private(set) var previewID: UUID?
    private(set) var target: LocalMacWindow?
    private var stream: SCStream?
    private var configuration: SCStreamConfiguration?
    private var nativeScale: CGFloat = 1
    private var displayBounds = CGRect.zero
    private var geometries: [LocalMacWindowFrame] = []
    private var includedWindowIDs: Set<UInt32> = []
    private var filterUpdateID: UUID?
    var onEnd: (() -> Void)?
    private let context = CIContext(options: [.cacheIntermediates: false])

    init(session: LocalMacSession, desktop: AccountCapture, output: Output) {
        self.session = session; self.desktop = desktop; self.output = output
    }
    func start(id: UUID, focus: AccountWindowFocus.Focus, count: Int) async throws {
        let window = focus.window
        let previous = stream
        stream = nil; geometries = []; displayBounds = .zero
        includedWindowIDs = []; filterUpdateID = nil
        previewID = id; target = window
        if let previous { try? await previous.stopCapture() }
        guard previewID == id else { return }
        do {
            let displayID = try desktop.verifiedDisplayID()
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard previewID == id else { return }
            guard try desktop.verifiedDisplayID() == displayID,
                  NLMPIDBelongsToUser(window.pid, session.account.uid),
                  let display = content.displays.first(where: { $0.displayID == displayID }),
                  let selected = content.windows.first(where: { $0.windowID == window.id && $0.owningApplication?.processID == window.pid }),
                  selected.frame.intersects(display.frame) else { throw LocalMacError("The focused window is no longer available.") }
            // Include the root plus explicit AX ancestors/dialogs. Some app-modal
            // dialogs are siblings in the window server, not attached children.
            let family = content.windows.filter {
                focus.relatedWindowIDs.contains($0.windowID) && $0.owningApplication?.processID == window.pid &&
                    $0.frame.intersects(display.frame)
            }
            let filter = SCContentFilter(display: display, including: family)
            filter.includeMenuBar = false
            let configuration = SCStreamConfiguration()
            // Native detail up to a bounded 16-megapixel surface; this does not
            // alter the account display or the remote window's size.
            nativeScale = max(1, CGFloat(filter.pointPixelScale))
            let scale = LocalMacWindowCaptureLimits.scale(bounds: display.frame, nativeScale: nativeScale, count: count)
            configuration.width = max(2, Int(display.frame.width * scale))
            configuration.height = max(2, Int(display.frame.height * scale))
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            // ScreenCaptureKit's default is clear. backgroundColor is an
            // assign/unowned CGColorRef: assigning a temporary here leaves a
            // dangling pointer that can crash the helper during startCapture.
            configuration.shouldBeOpaque = false
            configuration.ignoreShadowsDisplay = true
            configuration.includeChildWindows = true
            configuration.showsCursor = false // The local pointer must not expand the crop.
            configuration.capturesAudio = false
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 12)
            configuration.queueDepth = 3
            self.configuration = configuration
            displayBounds = display.frame
            let created = SCStream(filter: filter, configuration: configuration, delegate: self)
            try created.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
            stream = created
            includedWindowIDs = Set(family.map(\.windowID))
            try await created.startCapture()
            guard previewID == id, stream === created else { try? await created.stopCapture(); return }
        } catch {
            if previewID == id { await stop() }
            throw error
        }
    }
    func stop(id: UUID? = nil) async {
        if let id, previewID != id { return }
        let previous = stream
        stream = nil; configuration = nil; previewID = nil; target = nil; geometries = []; displayBounds = .zero
        includedWindowIDs = []; filterUpdateID = nil
        if let previous { try? await previous.stopCapture() }
    }
    func resizeBudget(count: Int) async {
        guard let stream, let configuration else { return }
        let scale = LocalMacWindowCaptureLimits.scale(bounds: displayBounds, nativeScale: nativeScale, count: count)
        configuration.width = max(2, Int(displayBounds.width * scale))
        configuration.height = max(2, Int(displayBounds.height * scale))
        do { try await stream.updateConfiguration(configuration) }
        catch { if self.stream === stream { end(error.localizedDescription) } }
    }
    func geometry(for input: LocalMacInput) throws -> LocalMacWindowFrame {
        _ = try desktop.verifiedDisplayID()
        guard let id = previewID, id == input.previewID, stream != nil, let target,
              NLMPIDBelongsToUser(target.pid, session.account.uid),
              let geometry = geometries.last(where: { $0.geometryID == input.geometryID }) else {
            throw LocalMacError("The window preview changed. Try again.")
        }
        return geometry
    }
    /// Stop on close, minimize, account/display loss, or process replacement.
    func check(focus: AccountWindowFocus.Focus?) {
        guard previewID != nil, let target else { return }
        let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard (try? desktop.verifiedDisplayID()) != nil, NLMPIDBelongsToUser(target.pid, session.account.uid),
              records.contains(where: { ($0[kCGWindowNumber as String] as? UInt32) == target.id &&
                  ($0[kCGWindowOwnerPID as String] as? Int32) == target.pid }) else {
            end("This window is no longer available."); return
        }
        if let focus, focus.window.id == target.id, focus.window.pid == target.pid,
           focus.relatedWindowIDs != includedWindowIDs, filterUpdateID == nil, let stream {
            let update = UUID(); filterUpdateID = update
            Task { await updateFilter(focus: focus, stream: stream, update: update) }
        }
    }
    private func updateFilter(focus: AccountWindowFocus.Focus, stream: SCStream, update: UUID) async {
        defer { if filterUpdateID == update { filterUpdateID = nil } }
        do {
            let displayID = try desktop.verifiedDisplayID()
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard filterUpdateID == update, self.stream === stream else { return }
            guard try desktop.verifiedDisplayID() == displayID,
                  NLMPIDBelongsToUser(focus.window.pid, session.account.uid),
                  let display = content.displays.first(where: { $0.displayID == displayID }) else {
                throw LocalMacError("The focused window's desktop is no longer available.")
            }
            let family = content.windows.filter {
                focus.relatedWindowIDs.contains($0.windowID) && $0.owningApplication?.processID == focus.window.pid &&
                    $0.frame.intersects(display.frame)
            }
            guard family.contains(where: { $0.windowID == focus.window.id }) else {
                throw LocalMacError("This window is no longer available.")
            }
            let filter = SCContentFilter(display: display, including: family)
            filter.includeMenuBar = false
            try await stream.updateContentFilter(filter)
            guard filterUpdateID == update, self.stream === stream else { return }
            includedWindowIDs = Set(family.map(\.windowID))
        } catch {
            if filterUpdateID == update, self.stream === stream { end(error.localizedDescription) }
        }
    }
    private func end(_ message: String) {
        guard let id = previewID else { return }
        let previous = stream
        stream = nil; previewID = nil; target = nil; geometries = []
        includedWindowIDs = []; filterUpdateID = nil
        onEnd?()
        var reply = LocalMacReply(error: message); reply.previewID = id; output.send(reply)
        Task { try? await previous?.stopCapture() }
    }
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        MainActor.assumeIsolated { deliver(stream, buffer: buffer, type: type) }
    }
    private func deliver(_ stream: SCStream, buffer: CMSampleBuffer, type: SCStreamOutputType) {
        guard self.stream === stream, let id = previewID, type == .screen, buffer.isValid,
              (try? desktop.verifiedDisplayID()) != nil,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              attachments.first?[.status] as? Int == SCFrameStatus.complete.rawValue,
              let pixel = buffer.imageBuffer, CVPixelBufferGetPixelFormatType(pixel) == kCVPixelFormatType_32BGRA else { return }
        let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
        CVPixelBufferLockBaseAddress(pixel, .readOnly)
        guard let address = CVPixelBufferGetBaseAddress(pixel) else { CVPixelBufferUnlockBaseAddress(pixel, .readOnly); return }
        let visible = NLMVisiblePixelBounds(address.assumingMemoryBound(to: UInt8.self), width, height, CVPixelBufferGetBytesPerRow(pixel))
        CVPixelBufferUnlockBaseAddress(pixel, .readOnly)
        guard !visible.isNull else { return }
        let crop = visible.insetBy(dx: -12, dy: -12).intersection(CGRect(x: 0, y: 0, width: width, height: height)).integral
        let bounds = CGRect(x: displayBounds.minX + crop.minX * displayBounds.width / CGFloat(width),
                            y: displayBounds.minY + crop.minY * displayBounds.height / CGFloat(height),
                            width: crop.width * displayBounds.width / CGFloat(width),
                            height: crop.height * displayBounds.height / CGFloat(height))
        var geometry = LocalMacWindowFrame(previewID: id, bounds: bounds, width: Int(crop.width), height: Int(crop.height))
        if let last = geometries.last, last.bounds == bounds, last.width == geometry.width, last.height == geometry.height {
            geometry = last
        } else {
            geometries.append(geometry)
            if geometries.count > 64 { geometries.removeFirst(geometries.count - 64) }
        }
        // CV buffers use a top-left origin; Core Image crops use bottom-left.
        let image = CIImage(cvPixelBuffer: pixel)
        let rectangle = CGRect(x: crop.minX, y: CGFloat(height) - crop.maxY, width: crop.width, height: crop.height)
        let opaque = image.composited(over: CIImage(color: .black).cropped(to: image.extent))
        guard let cg = context.createCGImage(opaque, from: rectangle),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { return }
        guard data.count <= 8 * 1_048_576 else { end("The window preview exceeds the image size limit."); return }
        var reply = LocalMacReply(); reply.frame = true; reply.data = data; reply.windowFrame = geometry
        output.send(reply)
    }
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let identifier = ObjectIdentifier(stream), message = error.localizedDescription
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.stream, ObjectIdentifier(current) == identifier else { return }
            self.end(message)
        }
    }
}
