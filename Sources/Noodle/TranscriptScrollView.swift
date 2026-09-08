import SwiftUI
import NoodleCore

struct TranscriptViewport: Equatable {
    var offset: CGFloat = 0
    var isAtBottom = true
}

private struct TranscriptGeometry: Equatable {
    let viewport: TranscriptViewport
    let contentHeight: CGFloat
    let containerHeight: CGFloat
}

/// Records geometry without publishing a SwiftUI update for every scrolled pixel.
private final class TranscriptViewportRecorder {
    var viewport: TranscriptViewport
    init(_ viewport: TranscriptViewport) { self.viewport = viewport }
}

/// The native transcript scroll container, also exercised by the resize fixture.
/// Message IDs let SwiftUI retain the reading position when rows reflow, without
/// corrective scrolling from geometry callbacks (which can cause layout loops).
struct TranscriptScrollView<Content: View>: View {
    let lastMessageID: UUID?
    let lastMessageIsFromUser: Bool
    let bottomOverlayHeight: CGFloat
    let saveViewport: (TranscriptViewport) -> Void
    private let content: Content
    @State private var position: ScrollPosition
    @State private var viewportRecorder: TranscriptViewportRecorder
    @State private var followsLatest: Bool
    @State private var userIsScrolling = false

    init(initialViewport: TranscriptViewport, lastMessageID: UUID?, lastMessageIsFromUser: Bool,
         bottomOverlayHeight: CGFloat, saveViewport: @escaping (TranscriptViewport) -> Void,
         @ViewBuilder content: () -> Content) {
        self.lastMessageID = lastMessageID
        self.lastMessageIsFromUser = lastMessageIsFromUser
        self.bottomOverlayHeight = bottomOverlayHeight
        self.saveViewport = saveViewport
        self.content = content()
        var initialPosition = ScrollPosition(idType: UUID.self)
        if initialViewport.isAtBottom {
            initialPosition.scrollTo(edge: .bottom)
        } else {
            initialPosition.scrollTo(y: initialViewport.offset)
        }
        _position = State(initialValue: initialPosition)
        _viewportRecorder = State(initialValue: TranscriptViewportRecorder(initialViewport))
        _followsLatest = State(initialValue: initialViewport.isAtBottom)
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: 10) {
                content
                // Clearance above the overlaid composer, not an anchor message.
                Color.clear.frame(height: bottomOverlayHeight + 20)
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
            guard oldSize.width > 0, oldSize != newSize, !followsLatest, !userIsScrolling,
                  let messageID = position.viewID(type: UUID.self) else { return }
            position.scrollTo(id: messageID, anchor: .top)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(followsLatest ? .bottom : .top, for: .sizeChanges)
        .defaultScrollAnchor(.top, for: .alignment)
        .onScrollGeometryChange(for: TranscriptGeometry.self) { geometry in
            let metrics = TranscriptScrollMetrics(
                contentOffset: geometry.contentOffset.y,
                contentHeight: geometry.contentSize.height,
                viewportHeight: geometry.containerSize.height,
                topInset: geometry.contentInsets.top,
                bottomInset: geometry.contentInsets.bottom
            )
            return TranscriptGeometry(
                // ScrollPosition(y:) uses the inset-adjusted top, not raw offset.
                viewport: TranscriptViewport(offset: metrics.offset, isAtBottom: metrics.isAtBottom),
                contentHeight: geometry.contentSize.height,
                containerHeight: geometry.containerSize.height
            )
        } action: { _, updated in
            viewportRecorder.viewport = updated.viewport
            // A later layout change must not be mistaken for a user scroll.
            if userIsScrolling, followsLatest != updated.viewport.isAtBottom {
                followsLatest = updated.viewport.isAtBottom
            }
            // Never write ScrollPosition here: native identity anchoring handles
            // reflow without a geometry -> corrective scroll -> geometry loop.
        }
        .onScrollPhaseChange { oldPhase, newPhase in
            let wasUserScrolling = oldPhase != .idle && oldPhase != .animating
            let isUserScrolling = newPhase != .idle && newPhase != .animating
            userIsScrolling = isUserScrolling
            if wasUserScrolling && !isUserScrolling {
                let finalViewport = viewportRecorder.viewport
                followsLatest = finalViewport.isAtBottom
                saveViewport(finalViewport)
            }
        }
        .onChange(of: lastMessageID) { _, _ in
            if lastMessageIsFromUser {
                followsLatest = true
                saveViewport(TranscriptViewport(offset: viewportRecorder.viewport.offset, isAtBottom: true))
            }
            if followsLatest && !userIsScrolling { position.scrollTo(edge: .bottom) }
        }
        // Save only real user scrolling, never the outgoing view's teardown geometry.
    }
}
