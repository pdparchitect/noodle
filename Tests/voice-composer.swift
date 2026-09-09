import AppKit
import AVFoundation
import SwiftUI
import NoodleCore

@main private enum VoiceComposerTest {
    @MainActor static func main() {
        guard #available(macOS 26, *) else { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                for key: UInt16 in [36, 53] {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-voice-keys-\(UUID())")
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: directory) }
                    let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
                    do {
                        let file = try AVAudioFile(forWriting: directory.appendingPathComponent("recording.caf"), settings: format.settings)
                        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
                        buffer.frameLength = 16_000
                        for i in 0..<16_000 { buffer.floatChannelData![0][i] = 0 }
                        try file.write(from: buffer)
                    }
                    let voice = VoiceMessage(transcript: "Keyboard fixture", duration: 1, waveform: [0], localeIdentifier: "en-GB")
                    try JSONEncoder().encode(VoiceRecordingDraft(voice: voice, transcriptionComplete: true))
                        .write(to: directory.appendingPathComponent("draft.json"))
                    let recorder = VoiceRecorder(directory: directory)
                    var sends = 0
                    let root = VoiceMessageComposer(recorder: recorder, send: { url, metadata in
                        precondition(FileManager.default.fileExists(atPath: url.path))
                        precondition(metadata.transcript == "Keyboard fixture")
                        sends += 1
                    }) { _ in Text("Existing text draft") }
                    .frame(width: 500).padding(20)
                    let window = NSWindow(contentViewController: NSHostingController(rootView: root))
                    window.title = "Voice composer keyboard fixture"
                    window.center()
                    window.makeKeyAndOrderFront(nil)
                    try await Task.sleep(for: .milliseconds(500))
                    let height = window.contentView!.fittingSize.height
                    precondition(abs(height - 76) < 1, "Voice bar must be 36pt plus 40pt fixture padding, got \(height)")
                    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                        windowNumber: window.windowNumber, context: nil, characters: key == 36 ? "\r" : "\u{1b}",
                        charactersIgnoringModifiers: key == 36 ? "\r" : "\u{1b}", isARepeat: false, keyCode: key)!
                    window.sendEvent(event)
                    try await Task.sleep(for: .milliseconds(400))
                    precondition(sends == (key == 36 ? 1 : 0), "Unexpected send count for key \(key): \(sends)")
                    precondition(recorder.phase == .idle, "Keyboard action did not clear the voice draft")
                    window.orderOut(nil)
                }
                print("PASS: Return sends one voice attachment; Escape discards without sending")
                exit(0)
            } catch { print(error); exit(1) }
        }
        app.run()
    }
}
