import AppKit
import HubLink
import NoodleCore
import NoodleRuntimeSettings
import SwiftUI

/// One action along the bottom of a profile: a button, Suspend with its choice of how long, or a view of the app's own
/// drawn with `ProfileActionLabel`.
struct ProfileCardAction: Identifiable {
    enum Kind {
        case button(title: String, systemImage: String, help: String, disabled: Bool, action: () -> Void)
        /// Unsuspend for one suspended; otherwise Suspend, offering how long. Nil lifts a suspension.
        case suspend(isSuspended: Bool, noun: String, set: (Date?) -> Void)
        case custom(AnyView)
    }

    let id: String
    let kind: Kind

    static func button(_ title: String, systemImage: String, help: String, disabled: Bool = false,
                       action: @escaping () -> Void) -> Self {
        Self(id: title, kind: .button(title: title, systemImage: systemImage, help: help, disabled: disabled, action: action))
    }

    static func suspend(isSuspended: Bool, noun: String, set: @escaping (Date?) -> Void) -> Self {
        Self(id: "suspend", kind: .suspend(isSuspended: isSuspended, noun: noun, set: set))
    }

    static func custom(_ id: String, _ view: some View) -> Self { Self(id: id, kind: .custom(AnyView(view))) }
}

extension ProfileCardAction {
    /// A bot's actions, in the same order in every app: Reply in a group, Message, Call, the app's own such as
    /// Computer and Browser, Edit, Usage, then Suspend. Calling shows the call's conversation, or else closes.
    /// A nil action is left out; Message without a conversation to open is dimmed.
    @MainActor static func botActions(noun: String, name: String, reply: (() -> Void)?, message: (() -> Void)?,
                                      canMessage: Bool = true, call: (() -> Void)?, close: @escaping () -> Void,
                                      extra: [ProfileCardAction] = [], edit: (() -> Void)?, usage: (() -> Void)?,
                                      suspension: (isSuspended: Bool, set: (Date?) -> Void)?) -> [Self] {
        var actions: [Self] = []
        if let reply { actions.append(.button("Reply", systemImage: "arrowshape.turn.up.left", help: "Reply in Group", action: reply)) }
        if let message {
            actions.append(.button("Message", systemImage: "bubble.left", help: "Direct Message", disabled: !canMessage, action: message))
        }
        if let call {
            actions.append(.button("Call", systemImage: "phone", help: "Call \(name)") {
                call()
                // The call's controls are in its conversation, so show it.
                (message ?? close)()
            })
        }
        actions += extra
        if let edit { actions.append(.button("Edit", systemImage: "pencil", help: "Edit \(noun)", action: edit)) }
        if let usage { actions.append(.button("Usage", systemImage: "chart.bar", help: "Show Usage", action: usage)) }
        if let suspension { actions.append(.suspend(isSuspended: suspension.isSuspended, noun: noun, set: suspension.set)) }
        return actions
    }
}

/// A bot's, agent's or group's profile, the same in every app: its picture and name, a status, what it is for, and
/// its actions, up to four a row. The app gives the picture, the status and the actions.
struct ProfileCard: View {
    let picture: AnyView
    let name: String
    /// Under the name, such as Archived or what the agent is doing; nil shows nothing there.
    var status: AnyView?
    let description: String
    var detail: String?
    let actions: [ProfileCardAction]
    let closeLabel: String
    let close: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(closeLabel)
            }
            picture
            Text(name)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            if let status { status }
            ScrollView {
                VStack(spacing: 8) {
                    Text(description).foregroundStyle(.secondary)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                }
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity)
            }
            .frame(maxHeight: 120)
            VStack(spacing: 8) {
                ForEach(ProfileActionRows.split(actions.map(\.id)), id: \.self) { row in
                    HStack(spacing: 8) {
                        ForEach(row, id: \.self) { id in
                            if id != row.first { Divider().frame(height: 32).accessibilityHidden(true) }
                            if let action = actions.first(where: { $0.id == id }) { view(for: action) }
                        }
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .frame(width: 320)
        .background(ProfileOutsideClickDismissal(dismiss: close))
    }

    @ViewBuilder private func view(for action: ProfileCardAction) -> some View {
        switch action.kind {
        case let .button(title, systemImage, help, disabled, perform):
            Button(action: perform) { ProfileActionLabel(title: title, systemImage: systemImage) }
                .disabled(disabled)
                .help(help)
                .accessibilityLabel(help)
        case let .suspend(isSuspended, noun, set):
            if isSuspended {
                Button { set(nil) } label: { ProfileActionLabel(title: "Unsuspend", systemImage: "play.circle") }
                    .help("Unsuspend \(noun)")
                    .accessibilityLabel("Unsuspend \(noun)")
            } else {
                // Looks like the buttons beside it; a click offers how long.
                Menu {
                    ForEach(LinkSuspensionChoice.allCases, id: \.self) { choice in
                        Button(choice.title) { set(choice.until()) }
                    }
                } label: {
                    ProfileActionLabel(title: "Suspend", systemImage: "pause.circle")
                }
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .help("Suspend \(noun)")
                .accessibilityLabel("Suspend \(noun)")
            }
        case let .custom(view):
            view
        }
    }

    /// The text a profile shows for what it is for, or that nothing was written yet.
    static func description(_ text: String?) -> String {
        let value = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "No description yet." : value
    }
}

/// Suspend, in a conversation's menu in every app: how long, or Unsuspend for one suspended. Nil lifts a suspension.
struct SuspendMenu: View {
    let isSuspended: Bool
    /// What is suspended, such as "Bot".
    let noun: String
    let set: (Date?) -> Void

    var body: some View {
        if isSuspended {
            Button("Unsuspend \(noun)") { set(nil) }
        } else {
            Menu("Suspend \(noun)") {
                ForEach(LinkSuspensionChoice.allCases, id: \.self) { choice in
                    Button(choice.title) { set(choice.until()) }
                }
            }
        }
    }
}

/// The capsule under a profile's name: Archived, a status, or what an agent is doing.
struct ProfileStatusBadge: View {
    let text: String
    var dot: Color?
    var faded = false
    var isProblem = false
    /// When the status was set, said under it.
    var setAt: Date?

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
                Text(text).lineLimit(2)
            }
            .font(.callout)
            .foregroundStyle(isProblem ? Color.red : faded ? Color.secondary : Color.primary)
            .multilineTextAlignment(.center)
            .textSelection(.enabled)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
            if let setAt {
                Text(setAt, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

extension ProfileStatusBadge {
    /// Archived, or the status the bot set itself, faded once older than a heartbeat, since the bot has had its
    /// chance to update it and it may no longer hold; nil when it set none.
    static func bot(_ agent: AgentRecord, heartbeat: TimeInterval) -> Self? {
        if agent.archivedAt != nil { return Self(text: "Archived", faded: true) }
        guard let status = agent.status else { return nil }
        return Self(text: status, faded: agent.isStatusStale(after: heartbeat), setAt: agent.statusSetAt)
    }
}

/// One of the actions along the bottom of a bot's or group's profile.
struct ProfileActionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
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
}

/// Informational profiles can be dismissed without a decision. Keep this local
/// to the profile: clicking outside an editor must not discard unsaved changes.
struct ProfileOutsideClickDismissal: NSViewRepresentable {
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
