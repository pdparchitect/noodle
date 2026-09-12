import AppKit
import SwiftUI
import Vision
import NoodleCore

@MainActor enum KeyboardBindingChecks {
    static func run() throws {
        let suite = "com.pdparchitect.noodle.keybindings-fixture.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let bindings = KeyboardBindings(defaults: defaults)
        func key(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code)!
        }
        let original = key(0, "A", flags: [.command, .shift, .capsLock])
        require(bindings.matches(.annotateSelection, event: original), "Default shortcut must ignore Caps Lock")
        let changed = key(40, "k", flags: [.command, .option])
        let custom = KeyboardBindings.binding(from: changed)!
        try bindings.set(custom, for: .annotateSelection)
        require(bindings.matches(.annotateSelection, event: changed) && !bindings.matches(.annotateSelection, event: original),
            "Rebinding must immediately enable the new combination and stop matching the old one")
        require(bindings.shortcut(for: .annotateSelection)?.key == KeyEquivalent(Character(custom.key)),
            "Menu key equivalents must read the same binding as native preview events")
        require(bindings.shortcut(for: .annotateSelection)?.modifiers == [.command, .option])
        require(KeyboardBindings(defaults: defaults).binding(for: .annotateSelection) == custom, "Preferences must survive reconstruction")
        bindings.recordingAction = .newBot
        require(!bindings.matches(.annotateSelection, event: changed) && bindings.shortcut(for: .annotateSelection) == nil,
            "Recording a shortcut must suppress command dispatch and menu equivalents")
        bindings.recordingAction = nil
        try bindings.set(nil, for: .annotateSelection)
        require(!bindings.matches(.annotateSelection, event: changed) && bindings.shortcut(for: .annotateSelection) == nil,
            "Cleared shortcuts must not trigger")
        let mouse = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        require(!bindings.matches(.annotateSelection, event: mouse), "Two missing bindings must never count as an event match")
        bindings.resetAll()
        require(defaults.object(forKey: KeyboardBindings.defaultsKey) == nil, "Restore Defaults must remove saved overrides")

        let recorderWindow = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80),
            styleMask: [.titled], backing: .buffered, defer: false)
        recorderWindow.isReleasedWhenClosed = false
        var recordingError: String?
        let recorder = ShortcutRecorderButton(action: .newBot, bindings: bindings) { recordingError = $0 }
        recorderWindow.contentView = recorder
        defer { recorder.stopRecording(); recorderWindow.close() }
        recorder.startRecording()
        require(bindings.recordingAction == .newBot, "The recorder must begin with its owning action")
        require(recorder.captureKey(changed) == nil && bindings.binding(for: .newBot) == custom,
            "Recording must save and consume the new combination")
        require(bindings.recordingAction == nil && recordingError == nil, "Successful recording must end capture")
        recorder.startRecording()
        let conflict = key(3, "f", flags: .command)
        require(recorder.captureKey(conflict) == nil && recordingError != nil && bindings.recordingAction == .newBot,
            "A conflicting key must stay in the recorder and explain the conflict")
        require(bindings.binding(for: .newBot) == custom, "Rejected input must preserve the prior shortcut")
        require(recorder.captureKey(key(53, "\u{1b}", flags: [])) == nil && bindings.recordingAction == nil,
            "Escape must cancel without dispatching to the application")
        recorder.startRecording()
        require(recorder.captureKey(key(51, "\u{8}", flags: [])) == nil && bindings.binding(for: .newBot) == nil,
            "Delete must clear the shortcut and remain consumed")
        recorder.startRecording()
        let inactiveEvent = key(0, "a", flags: [])
        require(recorder.eventMonitorHandler()(inactiveEvent) === inactiveEvent && bindings.recordingAction == nil,
            "The installed monitor must stop and pass through when its window is not key")
        bindings.resetAll()

        // Render the actual tab offscreen; native OCR catches missing rows and
        // verifies that the visible recorder label updates on a saved change.
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 580, height: 640),
            styleMask: [.titled], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: KeybindingsSettingsView(bindings: bindings).preferredColorScheme(.dark))
        defer { panel.close() }
        for _ in 0..<8 {
            panel.contentView?.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        let content = panel.contentView!
        let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-keybindings-settings.png")
        try bitmap.representation(using: .png, properties: [:])!.write(to: file)
        print("RENDER: \(file.path)")
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: bitmap.cgImage!).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").lowercased()
        for label in ["new bot", "new group", "search conversations", "add annotation", "annotate region", "save annotation comment", "restore defaults"] {
            require(text.contains(label), "Keybindings tab must display \(label): \(text)")
        }
        func buttons(in view: NSView) -> [ShortcutRecorderButton] {
            (view as? ShortcutRecorderButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
        }
        try bindings.set(custom, for: .annotateSelection)
        for _ in 0..<8 {
            content.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
        require(buttons(in: content).first { $0.shortcutAction == .annotateSelection }?.title == custom.displayName,
            "The existing Settings control must display changed bindings without reopening the tab")
        require(!panel.isVisible, "Keybindings validation must never show a window")
    }
}
