import AppletBridge
import AppletCore
import XCTest

@testable import NoodleApplet

/// A noodlet out of sight is silent on the Mac, but its recording is not.
@MainActor final class RecordingSoundTests: XCTestCase {
    func testABackgroundPageIsHeardInItsRecordingButNotOnTheMac() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "RecordingSound." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let library = AppletLibrary(root: root, defaults: defaults, installExamples: false, watchChanges: false)
        let runtime = AppletRuntime(library: library, defaults: defaults)
        // Web Audio for one part of the page, a media element for the other.
        let page = """
            <title>Tone</title><audio id=a loop src=tone.wav></audio><script>
            const context = new AudioContext(), tone = context.createOscillator(), gain = context.createGain();
            gain.gain.value = 0.3;
            tone.connect(gain).connect(context.destination);
            tone.start();
            </script>
            """
        var validate = AppletRequest(.validate)
        validate.path = "/author/Tone.noodlet"
        validate.owner = "author"
        validate.files = [
            "noodlet.json": try JSONEncoder().encode(NoodletManifest(title: "Tone")),
            "index.html": Data(page.utf8),
            "tone.wav": Self.wave(seconds: 2),
        ]
        let installed = try await runtime.handle(validate, identity: AppletBuildIdentity.current.noodleID).checked()
        let package = try library.package(for: try XCTUnwrap(installed.noodletID))
        var open = AppletRequest(.open)
        open.path = package.url.path
        open.owner = "author"
        open.mode = "background"
        let started = try await runtime.handle(open, identity: AppletBuildIdentity.current.noodleID).checked()
        let sessionID = try XCTUnwrap(started.sessionID)
        let session = try XCTUnwrap(runtime.sessions[sessionID])
        defer { session.stop() }

        var record = AppletRequest(.recordStart)
        record.sessionID = sessionID
        record.duration = 3
        _ = try await runtime.handle(record, identity: AppletBuildIdentity.current.noodleID).checked()
        try await Task.sleep(for: .milliseconds(700))
        _ = try await session.web?.evaluate("await document.getElementById('a').play(); return true")
        try await Task.sleep(for: .milliseconds(1300))
        var stop = AppletRequest(.recordStop)
        stop.sessionID = sessionID
        _ = try await runtime.handle(stop, identity: AppletBuildIdentity.current.noodleID).checked()

        XCTAssertTrue(try XCTUnwrap(session.web).muted, "Recording made the page audible on the Mac.")
        let captures = root.appendingPathComponent("Captures")
        let video = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: captures, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "mp4" })
        let levels = try await RecordingTests.levels(video)
        // The oscillator alone, then the oscillator with the media element over it.
        XCTAssertGreaterThan(levels(0.3, 0.6), 0.1, "The page's Web Audio is missing.")
        XCTAssertGreaterThan(levels(1.4, 1.8), levels(0.3, 0.6) + 0.05, "The media element is missing.")
    }

    /// A mono 16-bit sine, loud enough to tell apart from the oscillator.
    static func wave(seconds: Int) -> Data {
        let rate = 48000, count = rate * seconds
        var data = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append(UInt32(36 + count * 2))
        data.append(Data("WAVEfmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(rate)); append(UInt32(rate * 2))
        append(UInt16(2)); append(UInt16(16))
        data.append(Data("data".utf8))
        append(UInt32(count * 2))
        for frame in 0..<count { append(Int16(sin(Double(frame) * 2 * .pi * 660 / Double(rate)) * 20000)) }
        return data
    }
}
