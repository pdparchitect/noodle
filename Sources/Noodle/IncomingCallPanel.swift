import AppKit
import NoodleCore
import SwiftUI

/// What the ringing panel needs from the app whose bots place calls.
@MainActor protocol IncomingCallHost: AnyObject {
    var ringingCalls: [AgentCallRequest] { get set }
    /// False where nothing is shown, as in tests: calls are kept and no panel rings.
    var showsIncomingCalls: Bool { get }
    /// Ends the calls that rang for too long.
    func expireCalls(at now: Date)
    /// A call stopped ringing here, for the app to stop it wherever else it rings.
    func stoppedRinging(_ id: UUID)
    func isCallable(_ agentID: UUID) -> Bool
    func caller(_ agentID: UUID) -> AgentRecord?
    func answer(_ id: UUID)
    func decline(_ id: UUID)
    /// The caller's picture, 44 points across.
    func callerPicture(_ agent: AgentRecord) -> AnyView
    /// Rings with a time-sensitive notification, again every few seconds while the call rings.
    func ring(_ call: AgentCallRequest, from agent: AgentRecord)
    func stopRingingNotification()
}

extension IncomingCallHost {
    /// Rings a call: it joins those ringing, the panel shows it, and it expires when its time is up.
    func startRinging(_ request: AgentCallRequest) {
        ringingCalls.append(request)
        guard showsIncomingCalls else { return }
        IncomingCallPanel.shared.update(self)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, request.expiresAt.timeIntervalSinceNow)))
            self?.expireCalls(at: Date())
        }
    }

    /// Takes a call off those ringing, answered, declined or missed, and stops it ringing everywhere.
    func takeRingingCall(_ id: UUID) -> AgentCallRequest? {
        stoppedRinging(id)
        guard let index = ringingCalls.firstIndex(where: { $0.id == id }) else { return nil }
        let request = ringingCalls.remove(at: index)
        if showsIncomingCalls { IncomingCallPanel.shared.update(self) }
        return request
    }
}

/// Floats in the top right corner over every app and Space while a call rings. It rings with a
/// time-sensitive notification, so Focus and Do Not Disturb silence it as they choose.
@MainActor final class IncomingCallPanel {
    static let shared = IncomingCallPanel()
    static let size = NSSize(width: 360, height: 76)
    private var panel: NSPanel?
    private var ringer: Task<Void, Never>?

    func update(_ store: any IncomingCallHost) {
        guard !store.ringingCalls.isEmpty else {
            panel?.orderOut(nil)
            ringer?.cancel(); ringer = nil
            store.stopRingingNotification()
            return
        }
        let panel = self.panel ?? makePanel(store)
        self.panel = panel
        if let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.maxX - Self.size.width - 16, y: visible.maxY - Self.size.height - 16))
        }
        panel.orderFrontRegardless()
        guard ringer == nil else { return }
        ringer = Task { @MainActor [weak store] in
            while !Task.isCancelled, let store {
                if let call = store.ringingCalls.first(where: { store.isCallable($0.agentID) }), let agent = store.caller(call.agentID) {
                    store.ring(call, from: agent)
                }
                try? await Task.sleep(for: .seconds(4))
            }
        }
    }

    private func makePanel(_ store: any IncomingCallHost) -> NSPanel {
        let panel = IncomingCallWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.title = "Incoming Call"
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false
        // A screen being shared or recorded does not show who calls or why.
        panel.sharingType = .none
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: IncomingCallView(store: store))
        return panel
    }
}

/// Takes clicks without bringing the app forward first.
private final class IncomingCallWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// The ringing call: who calls and why, with Decline and Answer.
struct IncomingCallView: View {
    let store: any IncomingCallHost

    var body: some View {
        Group {
            if let call = store.ringingCalls.first(where: { store.isCallable($0.agentID) }), let agent = store.caller(call.agentID) {
                HStack(spacing: 12) {
                    store.callerPicture(agent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(agent.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(call.reason)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(agent.displayName) is calling: \(call.reason)")
                    button("Decline", systemImage: "phone.down.fill", color: .red) { store.decline(call.id) }
                    button("Answer", systemImage: "phone.fill", color: .green) { store.answer(call.id) }
                }
                .padding(.horizontal, 14)
                .frame(width: IncomingCallPanel.size.width, height: IncomingCallPanel.size.height)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .frame(width: IncomingCallPanel.size.width, height: IncomingCallPanel.size.height)
    }

    private func button(_ title: String, systemImage: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(color, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .help(title)
    }
}
