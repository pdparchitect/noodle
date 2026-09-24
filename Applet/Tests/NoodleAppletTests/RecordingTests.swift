import AVFoundation
import AppKit
import XCTest

@testable import NoodleApplet

final class RecordingTests: XCTestCase {
    /// A capture that costs about as much as a real noodlet screenshot, so the test measures the
    /// cadence the recorder keeps rather than the speed of a trivial image.
    @MainActor private func record(
        snapshotCost: Duration, duration: Double, size: CGSize = CGSize(width: 320, height: 200)
    ) async throws -> [CMTime] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let image = Self.filled(size)
        let recording = try AppletRecording(url: url, size: size)
        recording.start(
            snapshot: {
                try await Task.sleep(for: snapshotCost)
                return image
            }, duration: duration)
        try await Task.sleep(for: .milliseconds(Int(duration * 1000) + 400))
        try await recording.finish()
        let asset = AVURLAsset(url: url)
        let loaded = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(loaded.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var times: [CMTime] = []
        while let sample = output.copyNextSampleBuffer() {
            if sample.presentationTimeStamp.isNumeric { times.append(sample.presentationTimeStamp) }
        }
        return times.sorted { $0.seconds < $1.seconds }
    }

    /// The recorder used to sleep a fixed interval *after* each capture, so the cost of the
    /// snapshot came off the frame rate and a 20 ms capture recorded at about ten uneven frames a
    /// second. Waiting for the remainder of the slot instead is arithmetic, not a matter of how
    /// fast the machine running this test is.
    func testTheCostOfASnapshotDoesNotComeOffTheFrameRate() {
        let rate = Int64(AppletRecording.framesPerSecond)
        // A capture well inside one frame keeps every slot.
        for slot in Int64(0)..<10 {
            let elapsed = Double(slot) / Double(rate) + 0.020
            XCTAssertEqual(AppletRecording.slot(after: slot, elapsed: elapsed), slot + 1)
        }
        // One that overruns skips to the next slot that has not passed, rather than falling
        // further behind on every frame.
        XCTAssertEqual(AppletRecording.slot(after: 0, elapsed: 0.050), 2)
        XCTAssertEqual(AppletRecording.slot(after: 2, elapsed: 0.117), 4)
        // A capture slower than the whole recording still advances.
        XCTAssertGreaterThan(AppletRecording.slot(after: 5, elapsed: 0.0), 5)
    }

    /// Frames have to land on the frame grid: irregular presentation times judder on playback even
    /// when the average rate is high enough. Timestamps used to come from the clock, so they never
    /// did. How many frames a machine manages varies; where each one lands does not.
    @MainActor func testEveryFrameLandsOnTheFrameGrid() async throws {
        let times = try await record(snapshotCost: .milliseconds(5), duration: 1.0)
        XCTAssertFalse(times.isEmpty)
        for time in times {
            let slots = time.seconds * Double(AppletRecording.framesPerSecond)
            XCTAssertEqual(
                slots, slots.rounded(), accuracy: 0.001,
                "A frame is \(time.value)/\(time.timescale), which is not a whole frame.")
        }
        XCTAssertEqual(Set(times.map(\.seconds)).count, times.count, "A frame time repeats.")
    }

    /// Sound goes where it was heard: a noodlet that starts playing half a second into the
    /// recording must not have its sound pulled back to the start of the video.
    @MainActor func testSoundLandsInTheVideoWhereItWasHeard() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let size = CGSize(width: 320, height: 200)
        let image = Self.filled(size)
        let recording = try AppletRecording(url: url, size: size)
        recording.start(snapshot: { image }, duration: 1.0)
        let rate = Int(AppletRecording.audioRate)
        var tone: [Int16] = []
        for frame in 0..<(rate / 4) {
            let value = Int16(sin(Double(frame) * 2 * .pi * 440 / Double(rate)) * 16000)
            tone += [value, value]
        }
        recording.appendAudio(tone, at: 0.5)
        try await Task.sleep(for: .milliseconds(1400))
        try await recording.finish()
        let levels = try await Self.levels(url)
        XCTAssertLessThan(levels(0.05, 0.4), 0.01, "Sound before the noodlet played it.")
        XCTAssertGreaterThan(levels(0.55, 0.7), 0.2, "The noodlet's sound is missing.")
        XCTAssertLessThan(levels(0.8, 0.95), 0.01, "Sound after the noodlet stopped.")
    }

    /// A noodlet that made no sound still records a video, without a soundtrack.
    @MainActor func testARecordingWithoutSoundHasNoSoundtrack() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).mp4")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let size = CGSize(width: 320, height: 200)
        let recording = try AppletRecording(url: url, size: size)
        let image = Self.filled(size)
        recording.start(snapshot: { image }, duration: 0.3)
        try await Task.sleep(for: .milliseconds(600))
        try await recording.finish()
        let asset = AVURLAsset(url: url)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(video.count, 1)
        XCTAssertEqual(audio.count, 0)
    }

    private static func filled(_ size: CGSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }

    /// The root mean square of the recording's first channel between two times, in full scale.
    static func levels(_ url: URL) async throws -> (Double, Double) -> Double {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first, "The recording has no soundtrack.")
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: AppletRecording.audioRate, AVNumberOfChannelsKey: 2,
            ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
            var data = Data(count: CMBlockBufferGetDataLength(block))
            data.withUnsafeMutableBytes {
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
            }
            data.withUnsafeBytes { samples += $0.bindMemory(to: Float.self) }
        }
        return { from, to in
            let first = Int(from * AppletRecording.audioRate), last = Int(to * AppletRecording.audioRate)
            guard last * 2 <= samples.count, first < last else { return -1 }
            var sum = 0.0
            for frame in first..<last { sum += Double(samples[frame * 2] * samples[frame * 2]) }
            return (sum / Double(last - first)).squareRoot()
        }
    }
}
