import AVFoundation
import AppKit
import AppletBridge

@MainActor final class AppletRecording {
    let url: URL
    /// The picture is written as it is captured; the sound joins it when the recording ends.
    private let videoURL: URL
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let size: CGSize
    private var frames: Int64 = 0
    private var task: Task<Void, Never>?
    private var failure: Error?
    /// What the noodlet played, interleaved stereo at audioRate, from the start of the recording.
    private var sound: [Int16] = []
    private var limit = 0
    /// Frames are timed on a grid of this many slots per second, so playback is even. A noodlet
    /// that cannot be captured this fast lands on every second or third slot instead, which stays
    /// even and keeps the recording in real time.
    nonisolated static let framesPerSecond: Int32 = 30
    /// Runners hand over sound in this one format, so the recording needs no converter.
    nonisolated static let audioRate = 48000.0
    init(url: URL, size: CGSize) throws {
        self.url = url
        videoURL = url.deletingPathExtension().appendingPathExtension("video.mp4")
        self.size = CGSize(width: Int(size.width) / 2 * 2, height: Int(size.height) / 2 * 2)
        writer = try AVAssetWriter(outputURL: videoURL, fileType: .mp4)
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
        limit = Int(((duration + 1) * Self.audioRate).rounded()) * 2
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
                    let elapsed = Self.seconds(clock.now - start)
                    slot = Self.slot(after: slot, elapsed: elapsed)
                    let remaining = Double(slot) / rate - elapsed
                    if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
                } catch is CancellationError { break } catch {
                    failure = error
                    break
                }
            }
        }
    }
    /// Sound a runner hands over: base64 of interleaved 16-bit stereo, at most 2 MiB a piece.
    nonisolated static func samples(_ encoded: Any?) -> [Int16]? {
        guard let encoded = encoded as? String, encoded.utf8.count <= 2 * 1_048_576,
            let data = Data(base64Encoded: encoded), data.count % 4 == 0
        else { return nil }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }
    /// Places interleaved stereo samples where they were heard, `seconds` after the recording
    /// started. Runners time their sound themselves, so a noodlet that starts playing late, or
    /// pauses, keeps its place however the samples arrive.
    func appendAudio(_ samples: [Int16], at seconds: Double) {
        guard seconds.isFinite, seconds >= 0, samples.count % 2 == 0 else { return }
        let start = Int((seconds * Self.audioRate).rounded()) * 2
        let end = min(start + samples.count, limit)
        guard start < end else { return }
        if sound.count < end { sound += repeatElement(0, count: end - sound.count) }
        sound.replaceSubrange(start..<end, with: samples[..<(end - start)])
    }
    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    /// The slot to capture next, given how long the recording has been running. Waiting a fixed
    /// interval after each capture would add the cost of the snapshot to every frame and set the
    /// rate by it. Taking the next slot that has not passed keeps the grid even and the recording
    /// in real time however slow the capture is.
    nonisolated static func slot(after slot: Int64, elapsed: Double) -> Int64 {
        max(slot + 1, Int64(elapsed * Double(framesPerSecond)) + 1)
    }
    private func append(_ image: NSImage, at time: CMTime) async throws {
        // The encoder usually needs only a moment to catch up, and waiting for it must not block
        // the noodlet being captured. Waiting longer than a frame would cost more than the frame
        // is worth, so an encoder that stays behind loses this slot and the next capture takes a
        // later one, which keeps the grid even.
        var waited = 0
        while !input.isReadyForMoreMediaData, waited < 10 {
            try await Task.sleep(for: .milliseconds(3))
            waited += 1
        }
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
        defer { try? FileManager.default.removeItem(at: videoURL) }
        if sound.isEmpty {
            try FileManager.default.moveItem(at: videoURL, to: url)
        } else {
            try await Self.mux(video: videoURL, sound: sound, to: url)
        }
    }
    func cancel() {
        task?.cancel()
        task = nil
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: videoURL)
    }
    /// Copies the encoded picture as it is and adds the sound as AAC, cut to the picture's length.
    nonisolated private static func mux(video: URL, sound: [Int16], to url: URL) async throws {
        let asset = AVURLAsset(url: video)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw AppletError("The recorded video has no picture.")
        }
        let length = try await asset.load(.duration)
        let hint = try await track.load(.formatDescriptions).first
        let reader = try AVAssetReader(asset: asset)
        // Read only from the one queue that feeds the picture input.
        nonisolated(unsafe) let pictures = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(pictures)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let picture = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: hint)
        let audio = AVAssetWriterInput(
            mediaType: .audio,
            outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: audioRate,
                AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000,
            ])
        for input in [picture, audio] {
            guard writer.canAdd(input) else { throw AppletError("Video encoder is unavailable.") }
            writer.add(input)
        }
        guard reader.startReading(), writer.startWriting() else {
            throw reader.error ?? writer.error ?? AppletError("Cannot add sound to the video.")
        }
        writer.startSession(atSourceTime: .zero)
        let frames = min(sound.count / 2, Int(length.seconds * audioRate))
        let chunks = try SoundChunks(Array(sound[..<(frames * 2)]))
        async let copied: Void = pump(picture) { pictures.copyNextSampleBuffer() }
        async let encoded: Void = pump(audio) { chunks.next() }
        _ = await (copied, encoded)
        guard reader.status == .completed else {
            writer.cancelWriting()
            throw reader.error ?? AppletError("Cannot read the recorded video.")
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? AppletError("Video could not be finalized.")
        }
    }
    /// Feeds one input until its source runs dry. The writer interleaves by holding back
    /// whichever input is ahead, so each input needs its own queue.
    nonisolated private static func pump(
        _ input: AVAssetWriterInput, _ next: @escaping @Sendable () -> CMSampleBuffer?
    ) async {
        let queue = DispatchQueue(label: "NoodleApplet.Recording.\(input.mediaType.rawValue)")
        // Used only on its own queue once handed over.
        nonisolated(unsafe) let input = input
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let finished = SoundChunks.Flag()
            input.requestMediaDataWhenReady(on: queue) {
                while input.isReadyForMoreMediaData, !finished.value {
                    if let buffer = next(), input.append(buffer) { continue }
                    finished.value = true
                    input.markAsFinished()
                    done.resume()
                }
            }
        }
    }
}

/// Recorded sound cut into tenth-of-a-second sample buffers for the AAC encoder.
private final class SoundChunks: @unchecked Sendable {
    final class Flag: @unchecked Sendable { var value = false }
    private let samples: [Int16]
    private let format: CMAudioFormatDescription
    private var frame = 0
    private static let length = Int(AppletRecording.audioRate) / 10
    init(_ samples: [Int16]) throws {
        self.samples = samples
        var description = AudioStreamBasicDescription(
            mSampleRate: AppletRecording.audioRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2,
            mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard
            CMAudioFormatDescriptionCreate(
                allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
                magicCookieSize: 0, magicCookie: nil, extensions: nil,
                formatDescriptionOut: &format) == noErr, let format
        else { throw AppletError("Cannot describe the recorded sound.") }
        self.format = format
    }
    func next() -> CMSampleBuffer? {
        let count = min(Self.length, samples.count / 2 - frame)
        guard count > 0 else { return nil }
        defer { frame += count }
        let bytes = count * 4
        var block: CMBlockBuffer?
        guard
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
            let block,
            samples.withUnsafeBytes({
                CMBlockBufferReplaceDataBytes(
                    with: $0.baseAddress! + frame * 4, blockBuffer: block,
                    offsetIntoDestination: 0, dataLength: bytes)
            }) == noErr
        else { return nil }
        var buffer: CMSampleBuffer?
        guard
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block, formatDescription: format,
                sampleCount: count,
                presentationTimeStamp: CMTime(
                    value: CMTimeValue(frame), timescale: CMTimeScale(AppletRecording.audioRate)),
                packetDescriptions: nil, sampleBufferOut: &buffer) == noErr
        else { return nil }
        return buffer
    }
}
