import AVFoundation
import AppKit
import AppletBridge

@MainActor final class AppletRecording {
    let url: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let size: CGSize
    private var frames: Int64 = 0
    private var task: Task<Void, Never>?
    private var failure: Error?
    init(url: URL, size: CGSize) throws {
        self.url = url
        self.size = CGSize(width: Int(size.width) / 2 * 2, height: Int(size.height) / 2 * 2)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(self.size.width),
                AVVideoHeightKey: Int(self.size.height),
            ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
                kCVPixelBufferWidthKey as String: Int(self.size.width),
                kCVPixelBufferHeightKey as String: Int(self.size.height),
                kCVPixelBufferCGImageCompatibilityKey as String: true,
                kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            ])
        guard writer.canAdd(input) else { throw AppletError("Video encoder is unavailable.") }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? AppletError("Cannot start video encoder.")
        }
        writer.startSession(atSourceTime: .zero)
    }
    func start(snapshot: @escaping @MainActor () async throws -> NSImage, duration: Double) {
        task = Task { [weak self] in
            guard let self else { return }
            let start = Date()
            while !Task.isCancelled, Date().timeIntervalSince(start) < duration {
                do {
                    let image = try await snapshot()
                    try append(image, at: Date().timeIntervalSince(start))
                    try await Task.sleep(for: .milliseconds(83))
                } catch is CancellationError { break } catch {
                    failure = error
                    break
                }
            }
        }
    }
    private func append(_ image: NSImage, at seconds: Double) throws {
        guard input.isReadyForMoreMediaData else { return }
        var buffer: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool,
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess, let buffer,
            let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { throw AppletError("Cannot allocate video frame.") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: Int(size.width),
                height: Int(size.height), bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
        else { throw AppletError("Cannot draw video frame.") }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        context.draw(cg, in: CGRect(origin: .zero, size: size))
        guard
            adaptor.append(
                buffer, withPresentationTime: CMTime(seconds: seconds, preferredTimescale: 600))
        else { throw writer.error ?? AppletError("Video encoding failed.") }
        frames += 1
    }
    func finish() async throws {
        task?.cancel()
        await task?.value
        task = nil
        if let failure {
            writer.cancelWriting()
            throw failure
        }
        guard frames > 0 else {
            writer.cancelWriting()
            throw AppletError("No video frames were captured.")
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? AppletError("Video could not be finalized.")
        }
    }
    func cancel() {
        task?.cancel()
        task = nil
        writer.cancelWriting()
    }
}
