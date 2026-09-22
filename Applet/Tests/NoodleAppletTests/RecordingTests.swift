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
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
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

    /// The recorder used to sleep a fixed interval *after* each capture, so a slow noodlet pushed
    /// the real rate far below the advertised one and the video looked choppy.
    @MainActor func testCaptureRateIsNotReducedByTheCostOfEachSnapshot() async throws {
        let times = try await record(snapshotCost: .milliseconds(20), duration: 1.0)
        XCTAssertGreaterThanOrEqual(
            times.count, 20, "A 20 ms snapshot must not hold the recording below 20 fps.")
    }

    /// Frames have to land on an even grid: irregular presentation times judder on playback even
    /// when the average rate is high enough.
    @MainActor func testFramesLandOnAnEvenGrid() async throws {
        let times = try await record(snapshotCost: .milliseconds(5), duration: 1.0)
        let gaps = zip(times.dropFirst(), times).map { $0.seconds - $1.seconds }
        let nominal = try XCTUnwrap(gaps.min())
        for gap in gaps {
            XCTAssertEqual(
                gap / nominal, (gap / nominal).rounded(), accuracy: 0.2,
                "A frame arrived off the grid: \(gaps)")
        }
    }
}
