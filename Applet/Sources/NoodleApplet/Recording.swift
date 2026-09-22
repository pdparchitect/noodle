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
    /// Frames are timed on a grid of this many slots per second, so playback is even. A noodlet
    /// that cannot be captured this fast lands on every second or third slot instead, which stays
    /// even and keeps the recording in real time.
    static let framesPerSecond: Int32 = 30
    init(url: URL, size: CGSize) throws {
        self.url = url
        self.size = CGSize(width: Int(size.width) / 2 * 2, height: Int(size.height) / 2 * 2)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        // Screen recordings are mostly still with sharp text, so the bit rate is budgeted per
        // pixel and capped: enough for a readable noodlet, small enough to post.
        let pixels = Double(self.size.width * self.size.height) * Double(Self.framesPerSecond)
        input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(self.size.width),
                AVVideoHeightKey: Int(self.size.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Int(min(max(pixels * 0.2, 2_000_000), 12_000_000)),
                    AVVideoExpectedSourceFrameRateKey: Self.framesPerSecond,
                    AVVideoMaxKeyFrameIntervalKey: Self.framesPerSecond * 2,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                ],
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
            let rate = Double(Self.framesPerSecond)
            let clock = ContinuousClock(), start = clock.now
            let last = Int64((duration * rate).rounded())
            var slot: Int64 = 0
            while !Task.isCancelled, slot < last {
                do {
                    let image = try await snapshot()
                    try await append(image, at: CMTime(value: slot, timescale: Self.framesPerSecond))
                    // Waiting a fixed interval after each capture would let the cost of the
                    // snapshot set the frame rate. Take the next slot that has not passed yet and
                    // wait only for what is left of it.
                    let now = Self.seconds(clock.now - start)
                    slot = max(slot + 1, Int64(now * rate) + 1)
                    let remaining = Double(slot) / rate - now
                    if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
                } catch is CancellationError { break } catch {
                    failure = error
                    break
                }
            }
        }
    }
    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    private func append(_ image: NSImage, at time: CMTime) async throws {
        // Skipping the frame outright would tear a hole in the grid; the encoder only ever needs a
        // moment to catch up, and waiting for it must not block the noodlet being captured.
        var waited = 0
        while !input.isReadyForMoreMediaData, waited < 50 {
            try await Task.sleep(for: .milliseconds(2))
            waited += 1
        }
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
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw writer.error ?? AppletError("Video encoding failed.")
        }
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
