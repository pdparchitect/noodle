import AppKit
import QuartzCore
import SwiftUI

/// A stable native surface lets Core Animation dissolve between rendered frames
/// without keeping two live transcripts or fading the conversation to blank.
struct ConversationTransition<Content: View>: NSViewRepresentable {
    let conversationID: UUID
    @ViewBuilder var content: Content

    func makeNSView(context: Context) -> ConversationTransitionSurface {
        ConversationTransitionSurface(content: hostedContent(context), conversationID: conversationID)
    }

    func updateNSView(_ view: ConversationTransitionSurface, context: Context) {
        view.update(content: hostedContent(context), conversationID: conversationID,
                    reduceMotion: context.environment.accessibilityReduceMotion)
    }

    static func dismantleNSView(_ view: ConversationTransitionSurface, coordinator: ()) {
        view.cancelTransition()
    }

    private func hostedContent(_ context: Context) -> AnyView {
        AnyView(content.environment(\.self, context.environment))
    }
}

/// The transcript's own hosting view carries the dissolve. An AppKit wrapper
/// around it would be one more coordinate system between SwiftUI and the masked
/// transcript, and text drawn under a flip that later disagrees with the one it
/// is composited through appears vertically mirrored until its row is rebuilt.
@MainActor final class ConversationTransitionSurface: NSHostingView<AnyView> {
    // Core Animation stores CATransition under this reserved key even when a
    // different key is supplied. Use it for replacement and cancellation too.
    static let animationKey = "transition"
    private(set) var conversationID: UUID

    init(content: AnyView, conversationID: UUID) {
        self.conversationID = conversationID
        super.init(rootView: content)
        // The transcript sizes itself from the chat layout, not from its content.
        sizingOptions = []
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @MainActor required init(rootView: AnyView) {
        conversationID = UUID()
        super.init(rootView: rootView)
    }

    required init?(coder: NSCoder) { nil }

    func update(content: AnyView, conversationID: UUID, reduceMotion: Bool) {
        let switching = self.conversationID != conversationID
        self.conversationID = conversationID
        if reduceMotion { cancelTransition() }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rootView = content
        if switching, !reduceMotion, window != nil, !inLiveResize, !bounds.isEmpty {
            // Replacing the animation under one key also bounds rapid keyboard
            // navigation to the latest selection, with no queued completions.
            let dissolve = CATransition()
            dissolve.type = .fade
            dissolve.duration = 0.16
            dissolve.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer?.add(dissolve, forKey: Self.animationKey)
        }
        CATransaction.commit()
    }

    func cancelTransition() { layer?.removeAnimation(forKey: Self.animationKey) }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        cancelTransition()
        super.viewWillMove(toWindow: newWindow)
    }
}
