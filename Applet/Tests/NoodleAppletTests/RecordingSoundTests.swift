import AppletBridge
import AppletCore
import XCTest

@testable import NoodleApplet

/// A noodlet out of sight is silent on the Mac, but its recording is not.
@MainActor final class RecordingSoundTests: XCTestCase {
    func testABackgroundPageIsHeardInItsRecordingButNotOnTheMac() async throws {
        // Web Audio for one part of the page, a media element for the other.
        let page = """
            <title>Tone</title><audio id=a loop src=tone.wav></audio><script>
            const context = new AudioContext(), tone = context.createOscillator(), gain = context.createGain();
            gain.gain.value = 0.3;
            tone.connect(gain).connect(context.destination);
            tone.start();
            </script>
            """
        let (levels, muted) = try await record(page) { session in
            try await Task.sleep(for: .milliseconds(700))
            _ = try await session.web?.evaluate("await document.getElementById('a').play(); return true")
        }
        XCTAssertTrue(muted, "Recording made the page audible on the Mac.")
        // The oscillator alone, then the oscillator with the media element over it.
        XCTAssertGreaterThan(levels(0.3, 0.6), 0.1, "The page's Web Audio is missing.")
        XCTAssertGreaterThan(levels(1.4, 1.8), levels(0.3, 0.6) + 0.05, "The media element is missing.")
    }

    /// Games start their music as they load, often from an element that is never in the page.
    func testMusicAlreadyPlayingWhenTheRecordingStartsIsHeard() async throws {
        let page = """
            <title>Tone</title><script>
            window.music = new Audio('tone.wav');
            music.loop = true;
            </script>
            """
        let (levels, _) = try await record(page) { _ in } before: { session in
            _ = try await session.web?.evaluate("await music.play(); return true")
        }
        XCTAssertGreaterThan(levels(0.5, 1.5), 0.2, "The music playing before the recording is missing.")
    }

    /// Opens `page` in the background, records it for two seconds while `during` runs, and
    /// returns the recording's sound levels and whether the page stayed muted on the Mac.
    private func record(
        _ page: String, during: (AppletSession) async throws -> Void,
        before: (AppletSession) async throws -> Void = { _ in }
    ) async throws -> (levels: (Double, Double) -> Double, muted: Bool) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "RecordingSound." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: root); defaults.removePersistentDomain(forName: suite) }
        let library = botLibrary(root: root, defaults: defaults)
        let runtime = AppletRuntime(library: library, defaults: defaults)
        var validate = AppletRequest(.validate)
        validate.path = try botNoodlet([
            "noodlet.json": try JSONEncoder().encode(NoodletManifest(title: "Tone")),
            "index.html": Data(page.utf8),
            "tone.wav": Self.wave(seconds: 2),
        ], named: "Tone", owner: "author", root: root)
        validate.owner = "author"
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
        try await before(session)

        var record = AppletRequest(.recordStart)
        record.sessionID = sessionID
        record.duration = 3
        _ = try await runtime.handle(record, identity: AppletBuildIdentity.current.noodleID).checked()
        let clock = ContinuousClock(), start = clock.now
        try await during(session)
        try await Task.sleep(until: start + .seconds(2))
        var stop = AppletRequest(.recordStop)
        stop.sessionID = sessionID
        _ = try await runtime.handle(stop, identity: AppletBuildIdentity.current.noodleID).checked()

        let captures = root.appendingPathComponent("Captures")
        let video = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: captures, includingPropertiesForKeys: nil)
                .first { $0.pathExtension == "mp4" })
        return (try await RecordingTests.levels(video), try XCTUnwrap(session.web).muted)
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
