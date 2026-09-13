import AppKit
import SwiftUI
import NoodleCore

/// View-local playback keeps effects out of transcript layout and scroll restoration.
struct ConversationEffectsView: View {
    @Environment(NoodleStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let conversationID: UUID
    @State private var playing: ConversationEffect?
    @State private var startedAt = Date.distantPast
    @State private var windowReference = EffectWindowReference()

    private var isVisibleChat: Bool {
        guard let window = windowReference.window else { return false }
        return NSApp.isActive &&
            window.isVisible && !window.isMiniaturized && window.isKeyWindow && window.attachedSheet == nil
    }

    var body: some View {
        ZStack {
            if let playing, isVisibleChat {
                switch playing.supportedKind {
                case .confetti:
                    if reduceMotion {
                        // A still acknowledgement, rather than moving particles or flashing.
                        Text("🎉")
                            .font(.system(size: 40))
                            .padding(12)
                            .background(.regularMaterial, in: Circle())
                    } else {
                        ConfettiCanvas(seed: playing.id, startedAt: startedAt)
                    }
                case nil:
                    EmptyView()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .background(EffectWindowProbe(reference: windowReference))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: conversationID) {
            playing = nil
            let repository = store.repository
            while !Task.isCancelled {
                if playing != nil, Date().timeIntervalSince(startedAt) >= 4 {
                    playing = nil
                }
                if isVisibleChat, playing == nil {
                    // Filesystem I/O and locking must not block the main thread.
                    let event = await Task.detached(priority: .utility) {
                        try? repository.takePendingEffect(conversationID: conversationID)
                    }.value
                    guard !Task.isCancelled else { return }
                    if let event, isVisibleChat, event.expiresAt > Date() {
                        startedAt = Date()
                        playing = event
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

private struct ConfettiCanvas: View {
    let seed: UUID
    let startedAt: Date
    private let colors: [Color] = [.pink, .orange, .yellow, .mint, .cyan, .purple]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60)) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(startedAt)
                let seedValue = seed.uuidString.utf8.reduce(UInt64(0)) { ($0 &* 31) &+ UInt64($1) }
                for index in 0..<120 {
                    let phase = sample(seedValue, index, 1)
                    let time = elapsed - phase * 0.45
                    guard time >= 0, time < 3.8 else { continue }
                    let fromLeft = index.isMultiple(of: 2)
                    let direction = fromLeft ? 1.0 : -1.0
                    let velocityX = (0.18 + sample(seedValue, index, 2) * 0.45) * size.width
                    let velocityY = -(0.48 + sample(seedValue, index, 3) * 0.36) * size.height
                    let x = (fromLeft ? 0 : size.width) + direction * velocityX * time
                    let y = size.height * 0.72 + velocityY * time + size.height * 0.35 * time * time
                    var particle = context
                    particle.opacity = min(1, max(0, (3.8 - time) / 0.8))
                    particle.translateBy(x: x, y: y)
                    particle.rotate(by: .radians(time * (3 + phase * 8) * direction))
                    let width = 5 + sample(seedValue, index, 4) * 5
                    let flutter = 0.3 + abs(cos(time * 7 + phase * 6)) * 0.7
                    let rect = CGRect(x: -width / 2, y: -3, width: width, height: 6 * flutter)
                    particle.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(colors[index % colors.count]))
                }
            }
        }
    }

    private func sample(_ seed: UInt64, _ index: Int, _ salt: UInt64) -> Double {
        var value = seed &+ UInt64(index) &* 0x9E3779B97F4A7C15 &+ salt &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return Double((value ^ (value >> 31)) & 0xFFFF) / 65535
    }
}
