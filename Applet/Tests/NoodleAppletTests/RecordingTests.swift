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
}
