import AppKit
import AVFoundation
import SwiftUI
import NoodleCore

@main private enum VoiceComposerTest {
    @MainActor static func main() {
        guard #available(macOS 26, *) else { return }
        let first = LiveVoiceWaveform.bars(samples: [0.04], width: 600, height: 22)
        let later = LiveVoiceWaveform.bars(samples: [0.04, 0.02], width: 600, height: 22)
        precondition(first[0].width == 2.5 && later.allSatisfy { $0.width == 2.5 })
        precondition(first[0].minX - later[0].minX == 5, "Old bars scroll left without shrinking")
        precondition(first[0].height > 12, "Quiet speech should be visibly taller than silence")
        precondition(LiveVoiceWaveform.bars(samples: [0], width: 600, height: 22)[0].height == 2)
        precondition(LiveVoiceWaveform.bars(samples: [], width: 600, height: 22).isEmpty)
        precondition(LiveVoiceWaveform.bars(samples: [Float](repeating: 0.04, count: 240), width: 600, height: 22).count == 120)
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
                // Visual fixture uses synthetic amplitudes, never microphone audio.
                let speech: [Float] = (0..<150).map { index in
                    let envelope = max(0, sin(Float(index) * 0.22))
                    return index % 37 < 7 ? 0 : envelope * (0.01 + 0.03 * abs(sin(Float(index) * 0.71)))
                }
                let preview = VStack(alignment: .leading, spacing: 16) {
                    ForEach([1, 20, 150], id: \.self) { count in
                        Text("\(count) samples — fixed bar width").font(.caption)
                        LiveVoiceWaveform(samples: Array(speech.prefix(count)))
                            .frame(width: 600, height: 22).padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                    }
                }.padding(20).preferredColorScheme(.dark)
                let previewView = NSHostingView(rootView: preview)
                let previewWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 664, height: 310),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                previewWindow.contentView = previewView
                previewWindow.orderFront(nil)
                try await Task.sleep(for: .milliseconds(300))
                if let bitmap = previewView.bitmapImageRepForCachingDisplay(in: previewView.bounds) {
                    previewView.cacheDisplay(in: previewView.bounds, to: bitmap)
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-live-waveform-preview.png")
                    try bitmap.representation(using: .png, properties: [:])?.write(to: url)
                    print("Waveform preview: \(url.path)")
                }
                previewWindow.orderOut(nil)
                print("PASS: Return sends one voice attachment; Escape discards without sending")
                exit(0)
            } catch { print(error); exit(1) }
        }
        app.run()
    }
}
