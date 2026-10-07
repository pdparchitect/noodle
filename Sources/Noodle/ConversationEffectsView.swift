import AppKit
import SwiftUI
import NoodleBrand
import NoodleCore

/// View-local playback keeps effects out of transcript layout and scroll restoration.
struct ConversationEffectsView: View {
    @Environment(NoodleStore.self) private var store
    let conversationID: UUID
    @State private var playing: Playback?
    @State private var startedAt = Date.distantPast
    @State private var windowReference = EffectWindowReference()

    /// A preview has no queued event behind it, so playback keeps only what rendering needs.
    private struct Playback {
        let effect: ChatEffect?
        let seed: UUID
    }

    private var isVisibleChat: Bool {
        guard let window = windowReference.window else { return false }
        return NSApp.isActive &&
            window.isVisible && !window.isMiniaturized && window.isKeyWindow && window.attachedSheet == nil
    }

    var body: some View {
        ZStack {
            if let playing, isVisibleChat, let effect = playing.effect {
                ChatEffectView(effect: effect, seed: playing.seed, startedAt: startedAt)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(EffectWindowProbe(reference: windowReference))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: .previewEffect)) { notification in
            guard NoodleAppIdentity.isDevelopment, isVisibleChat,
                  let kind = notification.object as? ConversationEffectKind else { return }
            startedAt = Date()
            playing = Playback(effect: ChatEffect(rawValue: kind.rawValue), seed: UUID())
        }
        .task(id: conversationID) {
            playing = nil
            let repository = store.repository
            while !Task.isCancelled {
                if playing != nil, Date().timeIntervalSince(startedAt) >= ChatEffect.duration {
                    playing = nil
                }
                if isVisibleChat, playing == nil {
                    let taken: (id: UUID, kind: String)?
                    if let mirror = store.hubMirror(forConversation: conversationID) {
                        // A Hub bot's effect waits on the Hub, for whichever device shows the conversation first.
                        taken = mirror.hasWaitingEffect(in: conversationID)
                            ? await mirror.takeEffect(in: conversationID).map { ($0.id, $0.kind) } : nil
                    } else {
                        // Filesystem I/O and locking must not block the main thread.
                        taken = await Task.detached(priority: .utility) {
                            try? repository.takePendingEffect(conversationID: conversationID)
                        }.value.map { ($0.id, $0.kind) }
                    }
                    guard !Task.isCancelled else { return }
                    if let taken, isVisibleChat {
                        startedAt = Date()
                        playing = Playback(effect: ChatEffect(rawValue: taken.kind), seed: taken.id)
                    }
                } else if !isVisibleChat {
                    playing = nil
                }
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { return }
            }
        }
    }
}

@MainActor
private final class EffectWindowReference {
    weak var window: NSWindow?
}

private struct EffectWindowProbe: NSViewRepresentable {
    let reference: EffectWindowReference

    func makeNSView(context: Context) -> Probe {
        Probe(reference: reference)
    }

    func updateNSView(_ nsView: Probe, context: Context) {}

    final class Probe: NSView {
        let reference: EffectWindowReference
        init(reference: EffectWindowReference) {
            self.reference = reference
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func viewDidMoveToWindow() { reference.window = window }
    }
}
