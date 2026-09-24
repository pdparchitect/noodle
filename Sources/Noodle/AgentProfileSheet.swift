import AppKit
import SwiftUI
import NoodleCore
import NoodleRuntimeSettings

/// Deliberately uses only the public record, never the workspace/backstory.
struct AgentProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @Environment(NoodleStore.self) private var store
    let agent: AgentRecord
    let edit: () -> Void
    var canOpenDirectMessage = false
    var reply: (() -> Void)? = nil
    var directMessage: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close bot profile")
            }
            BotAvatar(agent: agent, size: 88)
            Text(agent.displayName)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            ScrollView {
                Text(description)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: 120)
            HStack(spacing: 8) {
                if let reply {
                    Button(action: reply) {
                        actionLabel("Reply", systemImage: "arrowshape.turn.up.left")
                    }
                    .help("Reply in Group")
                    .accessibilityLabel("Reply in Group")
                    Divider().frame(height: 32).accessibilityHidden(true)
                }
                if let directMessage {
                    Button(action: directMessage) {
                        actionLabel("Message", systemImage: "bubble.left")
                    }
                    .disabled(!canOpenDirectMessage)
                    .help("Direct Message")
                    .accessibilityLabel("Direct Message")
                    Divider().frame(height: 32).accessibilityHidden(true)
                }
                Button(action: edit) {
                    actionLabel("Edit", systemImage: "pencil")
                }
                .help("Edit Bot")
                .accessibilityLabel("Edit Bot")
                Divider().frame(height: 32).accessibilityHidden(true)
                Button {
                    store.usage.agentFilter = agent.id
                    openWindow(id: UsageView.windowID)
                    dismiss()
                } label: {
                    actionLabel("Usage", systemImage: "chart.bar")
                }
                .help("Show Usage")
                .accessibilityLabel("Show Usage")
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(width: 320)
        .background(ProfileOutsideClickDismissal { dismiss() })
    }

    private func actionLabel(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 18))
                .frame(height: 20)
            Text(title)
                .font(.caption)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private var description: String {
        let value = agent.publicDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "No description yet." : value
    }
}

/// Informational profiles can be dismissed without a decision. Keep this local
/// to the profile: clicking outside an editor must not discard unsaved changes.
private struct ProfileOutsideClickDismissal: NSViewRepresentable {
    let dismiss: () -> Void

    func makeNSView(context: Context) -> DismissalView { DismissalView() }

    func updateNSView(_ view: DismissalView, context: Context) {
        view.dismiss = dismiss
    }

    static func dismantleNSView(_ view: DismissalView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class DismissalView: NSView {
        var dismiss: (() -> Void)?
        private var mouseMonitor: Any?
        private var deactivationObserver: NSObjectProtocol?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                let outside = MainActor.assumeIsolated {
                    guard let self, let sheet = self.window, let parent = sheet.sheetParent,
                          event.window === parent else { return false }
                    let point = parent.convertPoint(toScreen: event.locationInWindow)
                    guard !sheet.frame.contains(point) else { return false }
                    self.dismiss?()
                    return true
                }
                // Dismiss only; don't activate whatever was behind the sheet.
                return outside ? nil : event
            }
            deactivationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: NSApp, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss?() }
            }
        }

        func stopMonitoring() {
            if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
            if let deactivationObserver { NotificationCenter.default.removeObserver(deactivationObserver) }
            mouseMonitor = nil
            deactivationObserver = nil
        }
    }
}
