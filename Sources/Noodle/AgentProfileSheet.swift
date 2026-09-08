import AppKit
import SwiftUI
import NoodleCore

/// Deliberately uses only the public record, never the workspace/backstory.
struct AgentProfileSheet: View {
    @Environment(\.dismiss) private var dismiss
    let agent: AgentRecord
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
            if reply != nil || directMessage != nil {
                VStack(spacing: 10) {
                    if let reply {
                        Button(action: reply) {
                            Label("Reply in Group", systemImage: "arrowshape.turn.up.left")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if let directMessage {
                        Button(action: directMessage) {
                            Label("Direct Message", systemImage: "bubble.left")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!canOpenDirectMessage)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 320)
        .background(ProfileOutsideClickDismissal { dismiss() })
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
