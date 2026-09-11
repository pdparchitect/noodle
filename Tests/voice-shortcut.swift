import AppKit
import Observation
import SwiftUI

@MainActor private enum FixtureWindows {
    static var byID: [String: NSWindow] = [:]
}

// Exercise native menu dispatch and SwiftUI scene focus with synthetic recorder
// states. No microphone, speech model, user recordings or messages are touched.
@available(macOS 26.0, *)
@MainActor @Observable private final class RecordingModel {
    var phase = VoiceRecorder.Phase.idle
    var sending = false
    var starts = 0
    var stops = 0

    var command: VoiceRecordingCommand {
        VoiceRecordingCommand(phase: { self.phase }, isSending: { self.sending }) {
            guard !self.sending else { return }
            switch self.phase {
            case .idle: self.starts += 1; self.phase = .preparing
            case .recording: self.stops += 1; self.phase = .finishing
            default: break
            }
        }
    }
}

@available(macOS 26.0, *)
@MainActor @Observable private final class ChatModel {
    var recording: RecordingModel? = RecordingModel()
    var text = "Existing draft"
    var sheet = false
}

@available(macOS 26.0, *)
@MainActor private enum Checks {
    static let first = ChatModel()
    static let second = ChatModel()
    static var started = false

    static func window(_ id: String) -> NSWindow {
        guard let window = FixtureWindows.byID[id] else {
            fixtureFailure("Missing fixture window: \(id)")
        }
        return window
    }

    static func menuItem() -> NSMenuItem {
        guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == "Conversation" })?.submenu else {
            fixtureFailure("Missing Conversation menu")
        }
        // SwiftUI constructs command items lazily when the menu opens.
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.update()
        guard let item = menu.items.first(where: {
            $0.keyEquivalent.lowercased() == "d" &&
            $0.keyEquivalentModifierMask.intersection([.command, .shift, .control, .option]) == [.command, .shift]
        }) else {
            fixtureFailure("Missing ⌘⇧D menu command")
        }
        return item
    }

    static func key(_ window: NSWindow, modifiers: NSEvent.ModifierFlags = [.command, .shift], repeated: Bool = false) async throws {
        // Synthetic events need the same lazy command validation as native
        // menu dispatch, including after replacing the selected conversation.
        _ = menuItem()
        let characters = modifiers.contains(.shift) ? "D" : "d"
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: "d",
                isARepeat: repeated, keyCode: 2)!
        NSApp.postEvent(event, atStart: false)
        try await Task.sleep(for: .milliseconds(150))
        let release = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: "d", isARepeat: false, keyCode: 2)!
        NSApp.postEvent(release, atStart: false)
        try await Task.sleep(for: .milliseconds(20))
    }

    static func run(openSettings: () -> Void) async {
        do {
            try await Task.sleep(for: .milliseconds(600))
            NSApp.activate(ignoringOtherApps: true)
            let firstWindow = window("voice-shortcut-first")
            let secondWindow = window("voice-shortcut-second")
            require(firstWindow !== secondWindow, "The fixture must create two distinct chat windows")
            firstWindow.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(200))
            let firstRecording = first.recording!
            require(menuItem().title == "Record Voice Message" && menuItem().isEnabled,
                "Initial menu: \(menuItem().title), enabled=\(menuItem().isEnabled), key=\(NSApp.keyWindow === firstWindow), active=\(NSApp.isActive)")
            try await key(firstWindow, modifiers: .command)
            try await key(firstWindow, modifiers: [.command, .shift, .option])
            require(firstRecording.starts == 0, "Only the exact shortcut should start recording")
            try await key(firstWindow)
            require(firstRecording.starts == 1 && firstRecording.phase == .preparing,
                "Start command failed: starts=\(firstRecording.starts), phase=\(firstRecording.phase)")
            require(!menuItem().isEnabled, "Startup must disable the command")
            try await key(firstWindow)
            require(firstRecording.starts == 1 && firstRecording.stops == 0)

            firstRecording.phase = .recording
            try await Task.sleep(for: .milliseconds(150))
            require(menuItem().title == "Stop Recording" && menuItem().isEnabled,
                "Recording menu: \(menuItem().title), enabled=\(menuItem().isEnabled), keyFirst=\(NSApp.keyWindow === firstWindow), keySecond=\(NSApp.keyWindow === secondWindow), secondStarts=\(second.recording!.starts), secondPhase=\(second.recording!.phase)")
            try await key(firstWindow, repeated: true)
            require(firstRecording.stops == 0, "Key repeat must not immediately stop recording")
            try await key(firstWindow)
            require(firstRecording.stops == 1 && firstRecording.phase == .finishing,
                "A second press must stop for review: stops=\(firstRecording.stops), phase=\(firstRecording.phase), key=\(NSApp.keyWindow === firstWindow)")
            for phase: VoiceRecorder.Phase in [.finishing, .ready, .failed] {
                firstRecording.phase = phase
                try await Task.sleep(for: .milliseconds(100))
                require(!menuItem().isEnabled, "An existing or unfinished voice draft must be protected")
                try await key(firstWindow)
                require(firstRecording.starts == 1 && firstRecording.stops == 1)
            }
            firstRecording.phase = .recording
            firstRecording.sending = true
            try await Task.sleep(for: .milliseconds(100))
            require(!menuItem().isEnabled, "Sending must disable the command")
            try await key(firstWindow)
            require(firstRecording.stops == 1)

            NSApp.activate(ignoringOtherApps: true)
            secondWindow.makeKeyAndOrderFront(nil)
            secondWindow.makeMain()
            try await Task.sleep(for: .milliseconds(200))
            require(NSApp.keyWindow === secondWindow,
                "Could not focus second fixture window; active=\(NSApp.isActive), key=\(String(describing: NSApp.keyWindow))")
            require(menuItem().title == "Record Voice Message" && menuItem().isEnabled,
                "Second menu: \(menuItem().title), enabled=\(menuItem().isEnabled)")
            try await key(secondWindow)
            require(second.recording!.starts == 1 && firstRecording.starts == 1,
                "The shortcut must target only the key chat window")

            let replacement = RecordingModel()
            second.recording = replacement
            try await Task.sleep(for: .milliseconds(150))
            try await key(secondWindow)
            require(replacement.starts == 1, "Switching chats must route to the new composer")
            second.recording = nil
            try await Task.sleep(for: .milliseconds(150))
            require(!menuItem().isEnabled, "No selected chat must disable recording")
            try await key(secondWindow)
            require(replacement.starts == 1)

            // A sheet must not trigger its underlying chat's recording command.
            firstRecording.phase = .idle
            firstRecording.sending = false
            firstWindow.makeKeyAndOrderFront(nil)
            first.sheet = true
            try await Task.sleep(for: .milliseconds(250))
            require(firstWindow.attachedSheet != nil)
            try await key(firstWindow.attachedSheet!)
            require(firstRecording.starts == 1, "A sheet must not start a background recording")
            first.sheet = false
            try await Task.sleep(for: .milliseconds(200))
            openSettings()
            try await Task.sleep(for: .milliseconds(300))
            let settings = window("voice-shortcut-settings")
            settings.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(150))
            require(!menuItem().isEnabled, "Settings must not inherit a chat's command")
            try await key(settings)
            require(firstRecording.starts == 1 && replacement.starts == 1)
            require(first.text == "Existing draft" && second.text == "Existing draft")
            print("PASS: ⌘⇧D starts/stops, ignores repeats, protects pending drafts, follows chats/windows, and stays inactive in sheets and Settings")
            fflush(stdout)
            exit(0)
        } catch {
            print("Voice shortcut fixture failed: \(error)")
            fflush(stdout)
            exit(1)
        }
    }
}

private struct WindowProbe: NSViewRepresentable {
    let id: String
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = view.window, FixtureWindows.byID[id] == nil { FixtureWindows.byID[id] = window }
        }
    }
}

@available(macOS 26.0, *)
private struct ChatRoot: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    let id: String
    @Bindable var model: ChatModel

    var body: some View {
        VStack {
            Text("Synthetic recording controls: \(id)")
            TextField("Draft", text: $model.text)
        }
        .padding(20).frame(width: 400, height: 160)
        .background(WindowProbe(id: "voice-shortcut-\(id)"))
        .focusedSceneValue(\.voiceRecordingCommand, model.recording?.command)
        .sheet(isPresented: $model.sheet) { TextField("Sheet input", text: $model.text).padding(20) }
        .task {
            guard !Checks.started else { return }
            Checks.started = true
            openWindow(value: "second")
            await Checks.run(openSettings: { openSettings() })
        }
    }
}

@available(macOS 26.0, *)
private struct VoiceShortcutApp: App {
    var body: some Scene {
        WindowGroup("Voice Shortcut Tests", for: String.self) { $id in
            ChatRoot(id: id ?? "first", model: id == "second" ? Checks.second : Checks.first)
        }
        .commands { ConversationCommands(search: {}) }
        Settings {
            Text("Synthetic settings").padding(20).frame(width: 300, height: 120)
                .background(WindowProbe(id: "voice-shortcut-settings"))
        }
    }
}

@main private enum VoiceShortcutTests {
    @MainActor static func main() {
        setbuf(stdout, nil)
        guard #available(macOS 26.0, *) else { print("SKIP: voice recording requires macOS 26"); return }
        NSApplication.shared.setActivationPolicy(.regular)
        VoiceShortcutApp.main()
    }
}
