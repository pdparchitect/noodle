import AppKit
import CoreImage
import CoreMedia
import LocalMacCore
import ScreenCaptureKit
import OSLog

/// All state and sample delivery are on the main queue. Captures the existing
/// account display; resolution changes and virtual-display creation live outside
/// this component and are not prerequisites for recording.
@MainActor final class AccountCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let session: LocalMacSession
    let output: Output
    var onChange: (() -> Void)?
    private(set) var displayID: UInt32?
    private(set) var bounds = CGRect.zero
    private(set) var error: String?
    private var protectedIDs: [UInt32] = []
    private var stream: SCStream?
    private var starting: UUID?
    private var lastImage: Data?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let log = Logger(subsystem: "com.pdparchitect.noodle.computer.desktop", category: "capture")

    init(session: LocalMacSession, output: Output) { self.session = session; self.output = output }

    func start(protectedDisplayIDs: [UInt32]) async {
        guard stream == nil, starting == nil else { return }
        let attempt = UUID(); starting = attempt
        defer { if starting == attempt { starting = nil; onChange?() } }
        do {
            try session.verifyCurrent()
            try LocalMacCapturePolicy.validateProtectedDisplays(protectedDisplayIDs)
            guard CGPreflightScreenCaptureAccess() else {
                throw LocalMacError("Allow Screen Recording for Noodle Local Mac Desktop, then reconnect.")
            }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard starting == attempt else { return }
            try session.verifyCurrent()
            let candidates = content.displays.filter {
                (try? LocalMacCapturePolicy.validate(displayID: $0.displayID,
                    isBuiltin: CGDisplayIsBuiltin($0.displayID) != 0, protectedIDs: protectedDisplayIDs)) != nil
            }
            guard candidates.count == 1, let display = candidates.first else {
                throw LocalMacError("Cannot identify a single display belonging only to this account.")
            }
            displayID = display.displayID; bounds = display.frame; protectedIDs = protectedDisplayIDs
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = session.account.display.width; config.height = session.account.display.height
            config.scalesToFit = true; config.preservesAspectRatio = true
            config.minimumFrameInterval = CMTime(value: 1, timescale: 12)
            config.queueDepth = 3; config.capturesAudio = false; config.showsCursor = true
            let created = SCStream(filter: filter, configuration: config, delegate: self)
            try created.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
            stream = created
            try await created.startCapture()
            guard starting == attempt, stream === created else { try? await created.stopCapture(); return }
            error = nil
            log.info("Capture started: desktop \(display.width) × \(display.height), output \(config.width) × \(config.height)")
        } catch {
            guard starting == attempt else { return }
            stream = nil; lastImage = nil; displayID = nil; bounds = .zero
            self.error = error.localizedDescription
        }
    }

    func stop() async {
        starting = nil
        let previous = stream
        stream = nil; lastImage = nil; displayID = nil; bounds = .zero; protectedIDs = []
        if let previous { try? await previous.stopCapture() }
        error = nil; onChange?()
    }

    func screenshot() throws -> Data {
        try session.verifyCurrent()
        guard stream != nil, let lastImage else {
            throw LocalMacError(error ?? "Waiting for the first desktop frame.")
        }
        return lastImage
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // ScreenCaptureKit was explicitly configured with sampleHandlerQueue .main.
        MainActor.assumeIsolated { deliver(stream, buffer: buffer, type: type) }
    }
    private func deliver(_ stream: SCStream, buffer: CMSampleBuffer, type: SCStreamOutputType) {
        guard type == .screen, self.stream === stream, buffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              attachments.first?[.status] as? Int == SCFrameStatus.complete.rawValue,
              (try? session.verifyCurrent()) != nil, let displayID,
              (try? LocalMacCapturePolicy.validate(displayID: displayID,
                  isBuiltin: CGDisplayIsBuiltin(displayID) != 0, protectedIDs: protectedIDs)) != nil,
              let pixel = buffer.imageBuffer else { return }
        let image = CIImage(cvPixelBuffer: pixel)
        guard let cg = context.createCGImage(image, from: image.extent),
              let data = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.78]) else { return }
        lastImage = data
        var reply = LocalMacReply(); reply.frame = true; reply.data = data; output.send(reply)
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        let identifier = ObjectIdentifier(stream)
        let message = error.localizedDescription
        DispatchQueue.main.async { [weak self] in
            guard let self, let current = self.stream, ObjectIdentifier(current) == identifier else { return }
            self.stream = nil; self.lastImage = nil; self.displayID = nil
            self.bounds = .zero; self.protectedIDs = []
            self.error = message; self.onChange?()
        }
    }
}
