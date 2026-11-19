import AppKit
import ApplicationServices
import SwiftUI
import NoodleCore
import NoodleRuntimeSettings

/// One group of shortcuts in Settings > Keybindings.
struct KeybindingsSection: Identifiable {
    let title: String
    let actions: [ShortcutDefinition]
    var footer: String?
    var id: String { title }

    /// Noodle's own.
    static let noodle: [KeybindingsSection] = [
        KeybindingsSection(title: "Conversations", actions: [.newBot, .newGroup, .searchConversations, .capture, .recordVoice, .call, .stopBot]),
        KeybindingsSection(title: "Any App", actions: [.chooseConversation, .chooseConversationWithContext]),
        KeybindingsSection(title: "Annotations", actions: [.annotateSelection, .annotateRegion, .saveAnnotation],
                           footer: "Select conversation text to add an annotation, or annotate a region of the Noodle window. The same shortcuts work in attachment previews. Escape cancels an annotation."),
    ]
}

struct KeybindingsSettingsView: View {
    var bindings = KeyboardBindings.shared
    var sections = KeybindingsSection.noodle
    @State private var errors: [ShortcutDefinition: String] = [:]
    @State private var accessibilityAllowed = AXIsProcessTrusted()

    var body: some View {
        VStack(spacing: 0) {
            Form {
                ForEach(sections) { section in
                    Section {
                        ForEach(section.actions) { row(bindings.own($0)) }
                    } header: {
                        Text(section.title)
                    } footer: {
                        if let footer = section.footer { Text(footer) }
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Text(bindings.recordingAction == nil
                    ? "Use ⌘, ⌃ or ⌥ with a key."
                    : bindings.recordingAction?.allowsDoubleTap == true
                    ? "Press a shortcut, or tap a modifier twice. Escape cancels; Delete clears."
                    : "Press a shortcut. Escape cancels; Delete clears.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Restore Defaults") { bindings.resetAll(); errors = [:] }
                    .disabled(bindings.isDefault && bindings.recordingAction == nil)
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
        }
        .onDisappear { bindings.recordingAction = nil }
        // Returning from System Settings is when Accessibility most likely changed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            accessibilityAllowed = AXIsProcessTrusted()
        }
    }

    private func reset(_ action: ShortcutDefinition) {
        if bindings.recordingAction == action { bindings.recordingAction = nil }
        do { try bindings.reset(action); errors[action] = nil }
        catch { errors[action] = error.localizedDescription }
    }

    private func row(_ action: ShortcutDefinition) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(action.title)
                Text(action.summary).font(.caption).foregroundStyle(.secondary)
                if let error = errors[action] { Text(error).font(.caption).foregroundStyle(.red) }
                if !accessibilityAllowed, bindings.binding(for: action) != nil,
                   action.needsAccessibility(with: bindings.binding(for: action)) {
                    HStack(spacing: 4) {
                        Text("Needs \(AppPermission.accessibility.name).").foregroundStyle(.orange)
                        Button("Open System Settings") {
                            if let url = AppPermission.accessibility.settingsURL { NSWorkspace.shared.open(url) }
                        }
                        .buttonStyle(.accentLink)
                    }
                    .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Shown only for a changed shortcut; the width is kept so the recorders stay aligned.
            Group {
                if bindings.isModified(action) {
                    Button { reset(action) } label: { Image(systemName: "arrow.counterclockwise") }
                        .buttonStyle(.borderless)
                        .help("Reset to \(action.defaultBinding.displayName)")
                        .accessibilityLabel("Reset \(action.title) to \(action.defaultBinding.displayName)")
                }
            }
            .frame(width: 20)
            ShortcutRecorder(action: action, bindings: bindings) { errors[action] = $0 }
                .frame(width: 112, height: 28)
                .contextMenu {
                    Button("Reset to \(action.defaultBinding.displayName)") { reset(action) }
                        .disabled(!bindings.isModified(action))
                    Button("Clear Shortcut") {
                        try? bindings.set(nil, for: action); errors[action] = nil
                    }.disabled(bindings.binding(for: action) == nil)
                }
        }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    let action: ShortcutDefinition
    let bindings: KeyboardBindings
    let onError: (String?) -> Void
    func makeNSView(context: Context) -> ShortcutRecorderButton {
        ShortcutRecorderButton(action: action, bindings: bindings, onError: onError)
    }
    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.onError = onError
        // Read observable properties in SwiftUI's update context too.
        button.refresh(label: bindings.label(for: action), recording: bindings.recordingAction == action)
    }
    static func dismantleNSView(_ button: ShortcutRecorderButton, coordinator: ()) { button.stopRecording() }
}

/// Captures only while this control's Settings window is key. The monitor
/// consumes recorded shortcuts before AppKit can dispatch menu commands.
@MainActor final class ShortcutRecorderButton: NSButton {
    let shortcutAction: ShortcutDefinition
    let bindings: KeyboardBindings
    var onError: (String?) -> Void
    private var monitor: Any?
    private weak var previousResponder: NSResponder?
    private var doubleTap = ModifierDoubleTap()
    private var keyPresses = 0

    init(action: ShortcutDefinition, bindings: KeyboardBindings, onError: @escaping (String?) -> Void) {
        shortcutAction = action; self.bindings = bindings; self.onError = onError
        super.init(frame: .zero)
        bezelStyle = .rounded; font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        target = self; self.action = #selector(toggleRecording)
        title = bindings.label(for: action)
        setAccessibilityLabel("Change shortcut for \(action.title)")
        toolTip = "Click to record a shortcut; right-click to reset or clear it."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var acceptsFirstResponder: Bool { true }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { stopRecording() }
        super.viewWillMove(toWindow: newWindow)
    }
    override func resignFirstResponder() -> Bool { stopRecording(restoreFocus: false); return super.resignFirstResponder() }

    @objc private func toggleRecording() {
        if monitor != nil { stopRecording() } else { startRecording() }
    }
    func startRecording() {
        guard monitor == nil, let window else { return }
        previousResponder = window.firstResponder
        guard window.makeFirstResponder(self) else { return }
        bindings.recordingAction = shortcutAction; onError(nil)
        title = "Press keys…"
        doubleTap = ModifierDoubleTap()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown],
            handler: eventMonitorHandler())
        NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey),
            name: NSWindow.didResignKeyNotification, object: window)
    }
    func eventMonitorHandler() -> (NSEvent) -> NSEvent? {
        { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }
    func handle(_ event: NSEvent) -> NSEvent? {
        guard monitor != nil else { return event }
        guard bindings.recordingAction == shortcutAction, NSApp.keyWindow === window else {
            stopRecording(); return event
        }
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            if event.type == .rightMouseDown || event.window !== window || !bounds.contains(convert(event.locationInWindow, from: nil)) { stopRecording() }
            return event
        }
        return captureKey(event)
    }
    /// Key processing is separate from window scoping so it can be verified
    /// without activating Settings or posting input to the user's desktop.
    func captureKey(_ event: NSEvent) -> NSEvent? {
        guard monitor != nil else { return event }
        if event.type == .flagsChanged {
            guard shortcutAction.allowsDoubleTap,
                  let modifier = doubleTap.update(held: KeyBinding.Modifiers(event.modifierFlags), keyPresses: keyPresses,
                                                  at: event.timestamp) else { return nil }
            do {
                try bindings.set(.doubleTap(modifier), for: shortcutAction)
                onError(nil); stopRecording()
            } catch { onError(error.localizedDescription) }
            return nil
        }
        guard event.type == .keyDown || event.type == .keyUp else { return event }
        if event.type == .keyUp || event.isARepeat { return nil }
        keyPresses += 1
        if event.keyCode == 53 { stopRecording(); return nil }
        let modifiers = event.modifierFlags.intersection([.command, .control, .shift, .option])
        if event.keyCode == 48 && modifiers.isEmpty { stopRecording(); return event }
        do {
            if (event.keyCode == 51 || event.keyCode == 117) && modifiers.isEmpty {
                try bindings.set(nil, for: shortcutAction)
            } else {
                guard let binding = KeyboardBindings.binding(from: event) else { throw ShortcutError.invalid }
                try bindings.set(binding, for: shortcutAction)
            }
            onError(nil); stopRecording()
        } catch { onError(error.localizedDescription) }
        return nil
    }
    func refresh(label: String, recording: Bool) {
        if monitor != nil && !recording { stopRecording() }
        title = monitor == nil ? label : "Press keys…"
    }
    @objc private func windowResignedKey() { stopRecording() }
    func stopRecording(restoreFocus: Bool = true) {
        guard let monitor else { return }
        self.monitor = nil; NSEvent.removeMonitor(monitor)
        NotificationCenter.default.removeObserver(self)
        if bindings.recordingAction == shortcutAction { bindings.recordingAction = nil }
        title = bindings.label(for: shortcutAction)
        if restoreFocus, window?.firstResponder === self { window?.makeFirstResponder(previousResponder) }
        previousResponder = nil
    }
}
