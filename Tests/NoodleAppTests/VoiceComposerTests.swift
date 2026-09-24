import AppKit
import AVFoundation
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle

/// The voice bar, its keys and its menu command, driven without a microphone:
/// ready drafts are written by hand as a silent CAF file plus draft.json.
@MainActor final class VoiceComposerTests: HiddenViewTests {
    private final class Sent { var transcripts: [String] = [] }

    private func readyRecorder(_ transcript: String) throws -> VoiceRecorder {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-voice-composer-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: directory.appendingPathComponent("recording.caf"), settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
            buffer.frameLength = 1_600
            buffer.floatChannelData![0].initialize(repeating: 0, count: 1_600)
            try file.write(from: buffer)
        }
        let voice = VoiceMessage(transcript: transcript, duration: 0.1, waveform: [0], localeIdentifier: "en-GB")
        try JSONEncoder().encode(VoiceRecordingDraft(voice: voice, transcriptionComplete: true))
            .write(to: directory.appendingPathComponent("draft.json"))
        let recorder = VoiceRecorder(directory: directory)
        XCTAssertEqual(recorder.phase, .ready)
        return recorder
    }

    private func composer(_ recorder: VoiceRecorder, sent: Sent) -> some View {
        VoiceMessageComposer(recorder: recorder, send: { url, metadata in
            XCTAssertEqual(url, recorder.audioURL, "Voice audio stays with the recorder that is sending")
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            sent.transcripts.append(metadata.transcript ?? "")
        }) { _ in Text("Text draft") }
        .frame(width: 500).padding(20)
    }

    private func key(_ keyCode: UInt16, in window: NSWindow) -> Bool {
        let characters = keyCode == 53 ? "\u{1b}" : (keyCode == 76 ? "\u{3}" : "\r")
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
        return window.performKeyEquivalent(with: event)
    }

    /// Live bars keep a fixed width and scroll 5pt per sample; silence is a 2pt line,
    /// quiet speech is clearly taller, and only as many bars as fit are drawn.
    func testLiveWaveformBarsKeepFixedScaleAndScroll() {
        let first = LiveVoiceWaveform.bars(samples: [0.04], width: 600, height: 22)
        let later = LiveVoiceWaveform.bars(samples: [0.04, 0.02], width: 600, height: 22)
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue((first + later).allSatisfy { $0.width == 2.5 })
        XCTAssertEqual(first[0].minX - later[0].minX, 5, "Older bars move left without shrinking")
        XCTAssertGreaterThan(first[0].height, 12, "Quiet speech is visibly taller than silence")
        XCTAssertEqual(LiveVoiceWaveform.bars(samples: [0], width: 600, height: 22).first?.height, 2)
        XCTAssertTrue(LiveVoiceWaveform.bars(samples: [], width: 600, height: 22).isEmpty)
        XCTAssertEqual(LiveVoiceWaveform.bars(samples: [Float](repeating: 0.04, count: 240), width: 600, height: 22).count, 120)
    }

    /// Return and keypad Enter send a ready voice draft and Escape discards it, even
    /// when something else in the chat window has focus.
    func testReturnEnterAndEscapeActOnReadyDraftWhereverFocusIs() async throws {
        for (keyCode, moveFocus) in [(36, false), (53, false), (36, true), (76, true), (53, true)] as [(UInt16, Bool)] {
            let recorder = try readyRecorder("Keyboard"), sent = Sent()
            let view = host(composer(recorder, sent: sent))
            let window = try XCTUnwrap(view.window)
            _ = try await control("Close", in: view)
            if moveFocus { XCTAssertTrue(window.makeFirstResponder(window)) }
            XCTAssertTrue(key(keyCode, in: window), "Key \(keyCode) was not handled, focus moved: \(moveFocus)")
            try await wait { recorder.phase == .idle }
            XCTAssertEqual(sent.transcripts, keyCode == 53 ? [] : ["Keyboard"], "Key \(keyCode), focus moved: \(moveFocus)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: recorder.audioURL.path))
        }
    }

    /// A composer reused for another conversation sends that conversation's voice
    /// draft and leaves the one it showed before untouched, and back again.
    func testSwappingRecorderSendsOnlyTheSelectedDraft() async throws {
        let first = try readyRecorder("First"), second = try readyRecorder("Second"), sent = Sent()
        let view = host(composer(first, sent: sent))
        let window = try XCTUnwrap(view.window)
        try await wait { view.layoutSubtreeIfNeeded(); return self.hasControl("Arrow Up Circle", in: view) }
        view.rootView = composer(second, sent: sent)
        view.layoutSubtreeIfNeeded()
        XCTAssertTrue(key(36, in: window))
        try await wait { second.phase == .idle }
        XCTAssertEqual(sent.transcripts, ["Second"])
        XCTAssertEqual(first.phase, .ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.audioURL.path))

        view.rootView = composer(first, sent: sent)
        view.layoutSubtreeIfNeeded()
        try await wait { view.layoutSubtreeIfNeeded(); return self.hasControl("Arrow Up Circle", in: view) }
        XCTAssertTrue(key(36, in: window))
        try await wait { first.phase == .idle }
        XCTAssertEqual(sent.transcripts, ["Second", "First"])
    }

    /// The menu item reads "Stop Recording" only while recording and is enabled only
    /// when idle or recording and not sending.
    func testRecordVoiceCommandTitleAndEnabledFollowRecorderPhase() {
        var phase = VoiceRecorder.Phase.idle, sending = false
        let command = VoiceRecordingCommand(phase: { phase }, isSending: { sending }, toggle: {})
        let expected: [(VoiceRecorder.Phase, String, Bool)] = [
            (.idle, "Record Voice Message", true), (.preparing, "Record Voice Message", false),
            (.recording, "Stop Recording", true), (.finishing, "Record Voice Message", false),
            (.ready, "Record Voice Message", false), (.failed, "Record Voice Message", false)]
        for (value, title, enabled) in expected {
            phase = value
            XCTAssertEqual(command.title, title, "\(value)")
            XCTAssertEqual(command.isEnabled, enabled, "\(value)")
        }
        sending = true
        for value in [VoiceRecorder.Phase.idle, .recording] {
            phase = value
            XCTAssertFalse(command.isEnabled, "Sending disables the command while \(value)")
        }
    }

    /// The command acts only on a chat window, and not while a shortcut is being recorded
    /// in Settings, where the keystroke belongs to the recorder.
    func testRecordVoiceCommandIgnoresMissingWindowAndShortcutRecording() {
        let suite = "noodle-voice-command-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let bindings = KeyboardBindings(defaults: defaults)
        var toggles = 0
        let command = VoiceRecordingCommand(phase: { .idle }, isSending: { false }, toggle: { toggles += 1 })
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        addTeardownBlock { @MainActor in window.close() }
        command.perform(in: nil, bindings: bindings)
        XCTAssertEqual(toggles, 0)
        bindings.recordingAction = .recordVoice
        command.perform(in: window, bindings: bindings)
        XCTAssertEqual(toggles, 0)
        bindings.recordingAction = nil
        command.perform(in: window, bindings: bindings)
        XCTAssertEqual(toggles, 1)
    }
}
