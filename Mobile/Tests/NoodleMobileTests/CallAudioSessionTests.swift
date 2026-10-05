import AVFAudio
@testable import NoodleMobile
import XCTest

/// Establishes the same category as an active call without opening a microphone.
/// These tests prove that other app audio changes the shared session; an actual
/// iPhone is still needed to establish the resulting routing and audible symptoms.
@MainActor final class CallAudioSessionTests: XCTestCase {
    func testOpeningANoodletPreservesTheCallRecordingCategory() throws {
        try withCallCategory { session in
            NoodletSound.start()
            XCTAssertEqual(session.category, .playAndRecord, "A noodlet must not remove the active call's recording capability")
        }
    }

    func testClosingANoodletPreservesTheCallRecordingCategory() throws {
        try withCallCategory { session in
            NoodletSound.stop()
            XCTAssertEqual(session.category, .playAndRecord, "Closing a noodlet must not replace the call's audio session")
        }
    }

    func testEvenFailedVoiceMessagePlaybackPreservesTheCallRecordingCategory() throws {
        try withCallCategory { session in
            let playback = VoicePlayback()
            let missing = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).missing-audio")
            playback.toggle(url: missing)
            XCTAssertNotNil(playback.error, "The missing recording must fail without playing any audio")
            XCTAssertEqual(session.category, .playAndRecord, "Playback must not switch a call to an output-only category")
        }
    }

    private func withCallCategory(_ body: (AVAudioSession) throws -> Void) throws {
        let session = AVAudioSession.sharedInstance()
        let category = session.category, mode = session.mode, options = session.categoryOptions
        defer {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try? session.setCategory(category, mode: mode, options: options)
        }
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        XCTAssertEqual(session.category, .playAndRecord)
        try body(session)
    }
}
