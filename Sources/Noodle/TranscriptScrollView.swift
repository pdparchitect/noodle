import SwiftUI
import NoodleCore

enum TranscriptScrollTarget: Hashable, Sendable {
    case start
    case message(UUID)
    case bottom

    var messageID: UUID? {
        if case .message(let id) = self { return id }
        return nil
    }
}

private struct TranscriptGeometry: Equatable {
    let viewport: TranscriptViewport
    let isAtTop: Bool
    let contentHeight: CGFloat
    let containerHeight: CGFloat
}

/// Changes only at the edges, so jump controls don't update on every scrolled pixel.
private struct TranscriptEdges: Equatable {
    var isAtTop: Bool
    var isAtBottom: Bool
}

/// Kept out of the scroll view's own state, so showing or fading a control
/// re-renders only the controls, never the ScrollView.
@MainActor @Observable
private final class TranscriptJumpState {
    var edges: TranscriptEdges
    var recentlyScrolled = false
    @ObservationIgnored private var hovering = false
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    init(isAtBottom: Bool) { edges = TranscriptEdges(isAtTop: false, isAtBottom: isAtBottom) }

    func scrollingBegan() {
        hideTask?.cancel()
        if !recentlyScrolled { recentlyScrolled = true }
    }

    func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, !self.hovering else { return }
            self.recentlyScrolled = false
        }
    }

    func setHovering(_ hovering: Bool) {
        self.hovering = hovering
        if hovering { hideTask?.cancel() } else if recentlyScrolled { scheduleHide() }
    }
}

/// Records geometry without publishing a SwiftUI update for every scrolled pixel.
private final class TranscriptViewportRecorder {
    var viewport: TranscriptViewport
    var lastUserViewport: TranscriptViewport?
    init(_ viewport: TranscriptViewport) { self.viewport = viewport }
}

/// The native transcript scroll container, also exercised by the resize fixture.
/// Message IDs let SwiftUI retain the reading position when rows reflow, without
/// corrective scrolling from geometry callbacks (which can cause layout loops).
struct TranscriptScrollView<Content: View>: View {
    private let initialViewport: TranscriptViewport
    let lastMessageID: UUID?
    let lastMessageIsFromUser: Bool
    let bottomOverlayHeight: CGFloat
    let saveViewport: (TranscriptViewport) -> Void
    private let content: Content
    @State private var position: ScrollPosition
    @State private var viewportRecorder: TranscriptViewportRecorder
    @State private var followsLatest: Bool
    @State private var userIsScrolling = false
    @State private var userHasScrolled = false
    @State private var didRestoreInitialViewport = false
    @State private var jumpState: TranscriptJumpState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(initialViewport: TranscriptViewport, lastMessageID: UUID?, lastMessageIsFromUser: Bool,
         bottomOverlayHeight: CGFloat, saveViewport: @escaping (TranscriptViewport) -> Void,
         @ViewBuilder content: () -> Content) {
        self.initialViewport = initialViewport
        self.lastMessageID = lastMessageID
        self.lastMessageIsFromUser = lastMessageIsFromUser
        self.bottomOverlayHeight = bottomOverlayHeight
        self.saveViewport = saveViewport
        self.content = content()
        let target = initialViewport.isAtBottom ? TranscriptScrollTarget.bottom
            : initialViewport.messageID.map(TranscriptScrollTarget.message) ?? .start
        let initialPosition = ScrollPosition(id: target, anchor: initialViewport.isAtBottom ? .bottom : .top)
        _position = State(initialValue: initialPosition)
        _viewportRecorder = State(initialValue: TranscriptViewportRecorder(initialViewport))
        _followsLatest = State(initialValue: initialViewport.isAtBottom)
        _jumpState = State(initialValue: TranscriptJumpState(isAtBottom: initialViewport.isAtBottom))
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 10) {
                content
                // Clearance above the overlaid composer, not an anchor message.
                Color.clear.frame(height: bottomOverlayHeight + 20)
                    .id(TranscriptScrollTarget.bottom)
            }
            .scrollTargetLayout()
            .padding(.horizontal, 15)
            .padding(.top, 30)
        }
        .scrollIndicators(.automatic, axes: .vertical)
        .contentMargins(.bottom, bottomOverlayHeight + 8, for: .scrollIndicators)
        .scrollPosition($position, anchor: .top)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { oldSize, newSize in
            // A lazy stack may revise estimated row heights during reflow.
            // Reassert the reading message only when the viewport changes size,
            // never when content height/offset changes, so this cannot feed back
            // into itself. Leave gestures and bottom-following to native scrolling.
            guard didRestoreInitialViewport, oldSize.width > 0, oldSize != newSize, !followsLatest, !userIsScrolling,
                  let target = position.viewID(type: TranscriptScrollTarget.self) else { return }
            position.scrollTo(id: target, anchor: .top)
        }
        .defaultScrollAnchor(initialViewport.isAtBottom ? .bottom : .top, for: .initialOffset)
        .defaultScrollAnchor(followsLatest ? .bottom : .top, for: .sizeChanges)
        .defaultScrollAnchor(.top, for: .alignment)
        .task(id: lastMessageID) {
            // Reassert a concrete row after attachment to the window. An edge
            // offset can land in a lazy stack's estimated, not-yet-realized extent.
            guard !didRestoreInitialViewport, lastMessageID != nil else { return }
            await Task.yield()
            guard !Task.isCancelled, !userHasScrolled else { return }
            didRestoreInitialViewport = true
            let target = initialViewport.isAtBottom ? TranscriptScrollTarget.bottom
                : initialViewport.messageID.map(TranscriptScrollTarget.message) ?? .start
            position.scrollTo(id: target, anchor: initialViewport.isAtBottom ? .bottom : .top)
        }
        .onScrollGeometryChange(for: TranscriptGeometry.self) { geometry in
            let metrics = Self.metrics(geometry)
            return TranscriptGeometry(
                // ScrollPosition(y:) uses the inset-adjusted top, not raw offset.
                viewport: TranscriptViewport(offset: metrics.offset, isAtBottom: metrics.isAtBottom),
                isAtTop: metrics.isAtTop,
                contentHeight: geometry.contentSize.height,
                containerHeight: geometry.containerSize.height
            )
        } action: { _, updated in
            viewportRecorder.viewport = updated.viewport
            // A later layout change must not be mistaken for a user scroll.
            if userIsScrolling, followsLatest != updated.viewport.isAtBottom {
                followsLatest = updated.viewport.isAtBottom
            }
            if userIsScrolling {
                viewportRecorder.lastUserViewport = readingViewport()
            }
            // Never write ScrollPosition here: native identity anchoring handles
            // reflow without a geometry -> corrective scroll -> geometry loop.
            // Published only at the edges, not for every scrolled pixel.
            let edges = TranscriptEdges(isAtTop: updated.isAtTop, isAtBottom: updated.viewport.isAtBottom)
            if jumpState.edges != edges { jumpState.edges = edges }
        }
        .onScrollPhaseChange { oldPhase, newPhase in
            let wasUserScrolling = oldPhase != .idle && oldPhase != .animating
            let isUserScrolling = newPhase != .idle && newPhase != .animating
            userIsScrolling = isUserScrolling
            if isUserScrolling {
                userHasScrolled = true
                didRestoreInitialViewport = true
                jumpState.scrollingBegan()
            }
            if wasUserScrolling && !isUserScrolling {
                let finalViewport = readingViewport()
                followsLatest = finalViewport.isAtBottom
                viewportRecorder.lastUserViewport = finalViewport
                saveViewport(finalViewport)
                jumpState.scheduleHide()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            TranscriptJumpControls(state: jumpState, jump: jump)
                .padding(.trailing, 18)
                .padding(.bottom, bottomOverlayHeight + 12)
        }
        .onChange(of: lastMessageID) { _, _ in
            // Initial hydration isn't a newly sent message, even if the last
            // stored message was authored by the user. Restoration owns it.
            guard didRestoreInitialViewport else { return }
            if lastMessageIsFromUser {
                followsLatest = true
                let latest = TranscriptViewport(offset: viewportRecorder.viewport.offset, isAtBottom: true)
                viewportRecorder.lastUserViewport = latest
                saveViewport(latest)
            }
            if followsLatest && !userIsScrolling {
                position.scrollTo(id: TranscriptScrollTarget.bottom, anchor: .bottom)
            }
        }
        .onDisappear { saveLastUserViewport() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            saveLastUserViewport()
        }
        // Save the captured user checkpoint, never an outgoing view's resized
        // teardown geometry. This also covers switching chats during a gesture.
    }

    private func readingViewport() -> TranscriptViewport {
        var viewport = viewportRecorder.viewport
        viewport.messageID = viewport.isAtBottom ? nil : position.viewID(type: TranscriptScrollTarget.self)?.messageID
        return viewport
    }

    private func saveLastUserViewport() {
        if let viewport = viewportRecorder.lastUserViewport { saveViewport(viewport) }
    }

    private func jump(to target: TranscriptScrollTarget) {
        let toBottom = target == .bottom
        userHasScrolled = true
        didRestoreInitialViewport = true
        followsLatest = toBottom
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.35)) {
            // The top edge needs no row: content may not provide a `.start` target,
            // and no estimated lazy-row height lies above offset zero.
            if toBottom { position.scrollTo(id: target, anchor: .bottom) } else { position.scrollTo(edge: .top) }
        }
        let viewport = TranscriptViewport(offset: 0, isAtBottom: toBottom)
        viewportRecorder.lastUserViewport = viewport
        saveViewport(viewport)
        jumpState.scheduleHide()
    }

    private static func metrics(_ geometry: ScrollGeometry) -> TranscriptScrollMetrics {
        TranscriptScrollMetrics(
            contentOffset: geometry.contentOffset.y,
            contentHeight: geometry.contentSize.height,
            // containerSize excludes the titlebar inset (758 vs 810 pt measured),
            // which kept isAtBottom false at the real bottom; visibleRect is full height.
            viewportHeight: geometry.visibleRect.height,
            topInset: geometry.contentInsets.top,
            bottomInset: geometry.contentInsets.bottom
        )
    }
}

private struct TranscriptJumpControls: View {
    let state: TranscriptJumpState
    let jump: (TranscriptScrollTarget) -> Void

    var body: some View {
        let showsTop = state.recentlyScrolled && !state.edges.isAtTop
        let showsBottom = state.recentlyScrolled && !state.edges.isAtBottom
        VStack(spacing: 8) {
            if showsTop { button("chevron.up", title: "Scroll to Top", target: .start) }
            if showsBottom { button("chevron.down", title: "Scroll to Latest", target: .bottom) }
        }
        .onHover { state.setHovering($0) }
        .animation(.easeOut(duration: 0.2), value: showsTop)
        .animation(.easeOut(duration: 0.2), value: showsBottom)
    }

    private func button(_ symbol: String, title: String, target: TranscriptScrollTarget) -> some View {
        Button { jump(target) } label: {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .modifier(JumpControlBackground())
        .help(title)
        .accessibilityLabel(title)
        .transition(.opacity)
    }
}

private struct JumpControlBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().stroke(.separator.opacity(0.5)))
        }
    }
}
