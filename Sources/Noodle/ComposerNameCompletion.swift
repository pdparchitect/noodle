import AppKit
import SwiftUI
import NoodleCore

@MainActor
final class ComposerNameCompletion: ObservableObject {
    @Published private(set) var candidates: [AgentRecord] = []
    @Published private(set) var selectedIndex = 0
    var popupHeight: CGFloat { CGFloat(min(5, candidates.count)) * 46 + 12 }
    private weak var editor: NSTextView?
    private var agents: [AgentRecord] = []
    private var preferredIDs: Set<UUID> = []
    private var request: AgentNameCompletion?
    private var dismissedRequest: AgentNameCompletion?
    private var observers: [NSObjectProtocol] = []
    private var keyMonitor: Any?

    func attach(to editor: NSTextView, agents: [AgentRecord], preferredIDs: Set<UUID>) {
        self.agents = agents
        self.preferredIDs = preferredIDs
        if self.editor !== editor {
            detach()
            self.editor = editor
            for notification in [NSText.didChangeNotification, NSTextView.didChangeSelectionNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: notification, object: editor, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refresh() }
                })
            }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let consumed = MainActor.assumeIsolated {
                    guard let self else { return false }
                    return self.handle(event) == nil
                }
                return consumed ? nil : event
            }
        }
        editor.isContinuousSpellCheckingEnabled = true
        editor.isGrammarCheckingEnabled = true
        editor.isAutomaticSpellingCorrectionEnabled = true
        refresh()
    }

    func detach() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        editor = nil
        request = nil
        dismissedRequest = nil
        if !candidates.isEmpty { candidates = [] }
    }

    private func refresh() {
        guard let editor, !editor.hasMarkedText(), editor.window?.firstResponder === editor else {
            if !candidates.isEmpty { candidates = [] }
            return
        }
        let updated = AgentNameCompletion.request(in: editor.string, selection: editor.selectedRange())
        if updated != request {
            selectedIndex = 0
            dismissedRequest = nil
        }
        request = updated
        let matches = updated == dismissedRequest ? [] : updated?.matches(agents, preferredIDs: preferredIDs) ?? []
        if candidates != matches { candidates = matches }
        if selectedIndex >= candidates.count { selectedIndex = 0 }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let editor, event.window === editor.window,
              editor.window?.firstResponder === editor, !editor.hasMarkedText(),
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return event }
        refresh()
        guard !candidates.isEmpty else { return event }
        switch event.keyCode {
        case 125: selectedIndex = (selectedIndex + 1) % candidates.count
        case 126: selectedIndex = (selectedIndex + candidates.count - 1) % candidates.count
        case 36, 48, 76: accept(candidates[selectedIndex])
        case 53:
            dismissedRequest = request
            candidates = []
        default: return event
        }
        return nil
    }

    func accept(_ agent: AgentRecord) {
        guard let editor, !editor.hasMarkedText(), let request,
              AgentNameCompletion.request(in: editor.string, selection: editor.selectedRange()) == request else { return }
        editor.window?.makeFirstResponder(editor)
        editor.breakUndoCoalescing()
        editor.insertText(request.replacement(name: agent.displayName, in: editor.string), replacementRange: request.range)
        editor.breakUndoCoalescing()
        refresh()
    }
}

/// Keeps SwiftUI's existing multiline field (including undo, paste and spelling)
/// and only intercepts completion keys while that specific field owns focus.
struct ChatComposerBridge: NSViewRepresentable {
    let isActive: Bool
    let draft: String
    let agents: [AgentRecord]
    let preferredIDs: Set<UUID>
    let completion: ComposerNameCompletion

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func makeCoordinator() -> ComposerNameCompletion { completion }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            guard isActive else { completion.detach(); return }
            guard let editor = view.window?.firstResponder as? NSTextView,
                  editor.string == draft else { return }
            completion.attach(to: editor, agents: agents, preferredIDs: preferredIDs)
        }
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ComposerNameCompletion) {
        coordinator.detach()
    }
}

struct AgentNameSuggestions: View {
    @ObservedObject var completion: ComposerNameCompletion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(completion.candidates.enumerated()), id: \.element.id) { index, agent in
                        Button { completion.accept(agent) } label: {
                            HStack(spacing: 10) {
                                BotAvatar(agent: agent, size: 28)
                                Text(agent.displayName).lineLimit(1)
                                Spacer()
                                if index == completion.selectedIndex {
                                    Image(systemName: "return").foregroundStyle(.secondary)
                                }
                            }
                            .padding(8)
                            .contentShape(Rectangle())
                            .background(index == completion.selectedIndex ? Color.accentColor.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Insert \(agent.displayName)")
                        .id(agent.id)
                    }
                }.padding(6)
            }
            .frame(width: 280, height: completion.popupHeight)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.separator.opacity(0.4)))
            .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
            .onChange(of: completion.selectedIndex) { _, index in
                if completion.candidates.indices.contains(index) { proxy.scrollTo(completion.candidates[index].id) }
            }
        }
    }
}
