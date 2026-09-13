import AppKit
import AVFoundation
import SwiftUI
import NoodleCore

@main private enum VoiceComposerTest {
    @MainActor static func main() {
        guard #available(macOS 26, *) else { return }
        let first = LiveVoiceWaveform.bars(samples: [0.04], width: 600, height: 22)
        let later = LiveVoiceWaveform.bars(samples: [0.04, 0.02], width: 600, height: 22)
        require(first[0].width == 2.5 && later.allSatisfy { $0.width == 2.5 })
        require(first[0].minX - later[0].minX == 5, "Old bars scroll left without shrinking")
        require(first[0].height > 12, "Quiet speech should be visibly taller than silence")
        require(LiveVoiceWaveform.bars(samples: [0], width: 600, height: 22)[0].height == 2)
        require(LiveVoiceWaveform.bars(samples: [], width: 600, height: 22).isEmpty)
        require(LiveVoiceWaveform.bars(samples: [Float](repeating: 0.04, count: 240), width: 600, height: 22).count == 120)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { fixtureFailure("Voice composer fixture timed out") }
        Task { @MainActor in
            do {
                @MainActor func keyEvent(_ key: UInt16, window: NSWindow) -> NSEvent {
                    let characters = key == 53 ? "\u{1b}" : (key == 76 ? "\u{3}" : "\r")
                    return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                        context: nil, characters: characters, charactersIgnoringModifiers: characters,
                        isARepeat: false, keyCode: key)!
                }
                for (key, moveFocus): (UInt16, Bool) in [(36, false), (53, false), (36, true), (76, true), (53, true)] {
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
                        require(FileManager.default.fileExists(atPath: url.path))
                        require(metadata.transcript == "Keyboard fixture")
                        sends += 1
                    }) { _ in Text("Existing text draft") }
                    .frame(width: 500).padding(20)
                    let window = NSWindow(contentViewController: NSHostingController(rootView: root))
                    window.title = "Voice composer keyboard fixture"
                    window.center()
                    window.makeKeyAndOrderFront(nil)
                    try await Task.sleep(for: .milliseconds(500))
                    let height = window.contentView!.fittingSize.height
                    require(abs(height - 76) < 1, "Voice bar must be 36pt plus 40pt fixture padding, got \(height)")
                    if moveFocus {
                        var dialogActions = 0
                        let dialog = NSWindow(contentViewController: NSHostingController(rootView:
                            HStack {
                                Button("Done") { dialogActions += 1 }.keyboardShortcut(.defaultAction)
                                Button("Cancel") { dialogActions += 1 }.keyboardShortcut(.cancelAction)
                            }.padding(20)))
                        // Sheets and other windows must keep their own default
                        // and cancel actions while this chat has a voice draft.
                        window.beginSheet(dialog, completionHandler: nil)
                        try await Task.sleep(for: .milliseconds(200))
                        app.sendEvent(keyEvent(key, window: dialog))
                        try await Task.sleep(for: .milliseconds(100))
                        require(dialogActions == 1 && sends == 0 && recorder.phase == .ready,
                            "A sheet must not submit or discard the underlying voice draft")
                        window.endSheet(dialog)
                        dialog.orderOut(nil)
                        try await Task.sleep(for: .milliseconds(200))
                        dialog.makeKeyAndOrderFront(nil)
                        try await Task.sleep(for: .milliseconds(100))
                        app.sendEvent(keyEvent(key, window: dialog))
                        try await Task.sleep(for: .milliseconds(100))
                        require(dialogActions == 2 && sends == 0 && recorder.phase == .ready,
                            "Another window must not submit or discard this chat's voice draft")
                        dialog.orderOut(nil)
                        window.makeKeyAndOrderFront(nil)
                    }
                    // The menu shortcut can start a recording while the sidebar
                    // or another chat control owns focus. Do not rely on the bar
                    // becoming first responder before Return/Escape will work.
                    if moveFocus {
                        require(window.makeFirstResponder(window), "Could not move focus outside the voice bar")
                    }
                    app.sendEvent(keyEvent(key, window: window))
                    try await Task.sleep(for: .milliseconds(400))
                    require(sends == (key == 53 ? 0 : 1), "Unexpected send count for key \(key), focus moved=\(moveFocus): \(sends)")
                    require(recorder.phase == .idle, "Keyboard action did not clear the voice draft")
                    window.orderOut(nil)
                }
                // Reuse the same composer while changing recorder identity. The
                // selected voice draft and its send closure must change together.
                let navigationRoot = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-voice-navigation-\(UUID())")
                defer { try? FileManager.default.removeItem(at: navigationRoot) }
                @MainActor func readyRecorder(_ name: String) throws -> VoiceRecorder {
                    let directory = navigationRoot.appendingPathComponent(name)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
                    do {
                        let file = try AVAudioFile(forWriting: directory.appendingPathComponent("recording.caf"), settings: format.settings)
                        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
                        buffer.frameLength = 160
                        buffer.floatChannelData![0].initialize(repeating: 0, count: 160)
                        try file.write(from: buffer)
                    }
                    let voice = VoiceMessage(transcript: name, duration: 0.01, waveform: [0], localeIdentifier: "en-GB")
                    try JSONEncoder().encode(VoiceRecordingDraft(voice: voice, transcriptionComplete: true))
                        .write(to: directory.appendingPathComponent("draft.json"))
                    return VoiceRecorder(directory: directory)
                }
                let firstRecorder = try readyRecorder("First"), secondRecorder = try readyRecorder("Second")
                var sentDrafts: [String] = []
                @MainActor func navigationContent(_ recorder: VoiceRecorder) -> some View {
                    VoiceMessageComposer(recorder: recorder, send: { url, metadata in
                        require(url == recorder.audioURL, "Voice audio must stay with its send destination")
                        sentDrafts.append(metadata.transcript ?? "")
                    }) { _ in Text("Text draft") }.frame(width: 500).padding(20)
                }
                let navigationHost = NSHostingView(rootView: navigationContent(firstRecorder))
                let navigationWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 76),
                    styleMask: [.titled], backing: .buffered, defer: false)
                navigationWindow.isReleasedWhenClosed = false
                navigationWindow.contentView = navigationHost
                navigationWindow.makeKeyAndOrderFront(nil)
                try await Task.sleep(for: .milliseconds(150))
                navigationHost.rootView = navigationContent(secondRecorder)
                try await Task.sleep(for: .milliseconds(150))
                app.sendEvent(keyEvent(36, window: navigationWindow))
                try await Task.sleep(for: .milliseconds(300))
                require(sentDrafts == ["Second"] && secondRecorder.phase == .idle && firstRecorder.phase == .ready,
                    "Switching must send only the selected recorder and preserve the other voice draft")
                navigationHost.rootView = navigationContent(firstRecorder)
                try await Task.sleep(for: .milliseconds(150))
                app.sendEvent(keyEvent(36, window: navigationWindow))
                try await Task.sleep(for: .milliseconds(300))
                require(sentDrafts == ["Second", "First"] && firstRecorder.phase == .idle,
                    "Returning must restore the original voice draft and its send action")
                navigationWindow.close()

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
                print("PASS: Return/keypad Enter send and Escape discards regardless of voice-bar focus; sheets and other windows keep their own actions; navigation preserves voice draft destinations")
                exit(0)
            } catch { print(error); exit(1) }
        }
        app.run()
    }
}
