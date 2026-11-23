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
    let contentHeight: CGFloat
    let containerHeight: CGFloat
    let farFromEnd: Bool
}

/// Records geometry without publishing a SwiftUI update for every scrolled pixel.
private final class TranscriptViewportRecorder {
    var viewport: TranscriptViewport
    var lastUserViewport: TranscriptViewport?
    init(_ viewport: TranscriptViewport) { self.viewport = viewport }
}

/// Layout figures the transcript and its rows share.
enum TranscriptMetrics {
    /// The gap between transcript rows.
    static let rowSpacing: CGFloat = 10
    /// Below this width, as in a column, bubbles may take nearly all of it.
    static let narrowWidth: CGFloat = 560
}

extension EnvironmentValues {
    @Entry var isNarrowTranscript = false
    /// A video or shader plays behind the transcript. It is not dimmed, so bubbles and cards are dark glass over
    /// it, outgoing bubbles solid accent, and captions white with a shadow.
    @Entry var transcriptOverMotion = false
}

/// The dark glass bubbles and cards take over a moving background.
struct TranscriptGlass<S: Shape>: View {
    let shape: S
    var body: some View {
        shape.fill(.ultraThinMaterial).overlay { shape.fill(Color.black.opacity(0.4)) }
    }
}

/// A caption in the transcript, such as a time or a delivery state: in the given style, or over a moving
/// background white with a soft shadow, as the background's colours vary beneath it.
struct TranscriptCaptionStyle: ViewModifier {
    let style: HierarchicalShapeStyle
    @Environment(\.transcriptOverMotion) private var overMotion

    func body(content: Content) -> some View {
        if overMotion {
            content.foregroundStyle(Color.white.opacity(0.85)).shadow(color: .black.opacity(0.35), radius: 2, y: 0.5)
        } else {
            content.foregroundStyle(style)
        }
    }
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
    let onInteraction: () -> Void
    /// Whether a message this view could be asked to reveal is one of its rows.
    let containsMessage: (UUID) -> Bool
    /// A click that lands on no message, which starts typing.
    let onBackgroundTap: () -> Void
    private let content: Content
    @State private var position: ScrollPosition
    @State private var viewportRecorder: TranscriptViewportRecorder
    @State private var followsLatest: Bool
    @State private var userIsScrolling = false
    @State private var userHasScrolled = false
    @State private var didRestoreInitialViewport = false
    /// Whether the reader is more than `TranscriptScrollMetrics.scrollToLatestDistance` above the end.
    /// Changes only when that distance is crossed, not for every scrolled pixel.
    @State private var farFromEnd: Bool
    @State private var isNarrow = false

    init(initialViewport: TranscriptViewport, lastMessageID: UUID?, lastMessageIsFromUser: Bool,
         bottomOverlayHeight: CGFloat, saveViewport: @escaping (TranscriptViewport) -> Void,
         onInteraction: @escaping () -> Void = {}, containsMessage: @escaping (UUID) -> Bool = { _ in false },
         onBackgroundTap: @escaping () -> Void = {}, @ViewBuilder content: () -> Content) {
        self.initialViewport = initialViewport
        self.lastMessageID = lastMessageID
        self.lastMessageIsFromUser = lastMessageIsFromUser
        self.bottomOverlayHeight = bottomOverlayHeight
        self.saveViewport = saveViewport
        self.onInteraction = onInteraction
        self.containsMessage = containsMessage
        self.onBackgroundTap = onBackgroundTap
        self.content = content()
        let target = initialViewport.isAtBottom ? TranscriptScrollTarget.bottom
            : initialViewport.messageID.map(TranscriptScrollTarget.message) ?? .start
        let initialPosition = ScrollPosition(id: target, anchor: initialViewport.isAtBottom ? .bottom : .top)
        _position = State(initialValue: initialPosition)
        _viewportRecorder = State(initialValue: TranscriptViewportRecorder(initialViewport))
        _followsLatest = State(initialValue: initialViewport.isAtBottom)
        _farFromEnd = State(initialValue: !initialViewport.isAtBottom)
    }

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(spacing: TranscriptMetrics.rowSpacing) {
                content
                // Clearance above the overlaid composer, not an anchor message.
                Color.clear.frame(height: bottomOverlayHeight + 20)
                    .id(TranscriptScrollTarget.bottom)
            }
            .scrollTargetLayout()
            .padding(.horizontal, 15)
            .padding(.top, 30)
            .environment(\.isNarrowTranscript, isNarrow)
            // Behind the rows, so only clicks between and beside messages reach it.
            .background { Color.clear.contentShape(Rectangle()).onTapGesture(perform: onBackgroundTap) }
        }
        // The space below a short transcript.
        .background { Color.clear.contentShape(Rectangle()).onTapGesture(perform: onBackgroundTap) }
        .onGeometryChange(for: Bool.self) { $0.size.width < TranscriptMetrics.narrowWidth } action: { isNarrow = $0 }
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
            let metrics = TranscriptScrollMetrics(
                contentOffset: geometry.contentOffset.y,
                contentHeight: geometry.contentSize.height,
                // containerSize leaves out the titlebar the transcript runs up behind,
                // which would put the end that much further down than it is.
                viewportHeight: geometry.visibleRect.height,
                topInset: geometry.contentInsets.top,
                bottomInset: geometry.contentInsets.bottom
            )
            return TranscriptGeometry(
                // ScrollPosition(y:) uses the inset-adjusted top, not raw offset.
                viewport: TranscriptViewport(offset: metrics.offset, isAtBottom: metrics.isAtBottom),
                contentHeight: geometry.contentSize.height,
                containerHeight: geometry.containerSize.height,
                farFromEnd: metrics.isFarFromEnd
            )
        } action: { _, updated in
            viewportRecorder.viewport = updated.viewport
            if farFromEnd != updated.farFromEnd { farFromEnd = updated.farFromEnd }
            // A later layout change must not be mistaken for a user scroll.
            if userIsScrolling, followsLatest != updated.viewport.isAtBottom {
                followsLatest = updated.viewport.isAtBottom
            }
            if userIsScrolling {
                viewportRecorder.lastUserViewport = readingViewport()
            }
            // Never write ScrollPosition here: native identity anchoring handles
            // reflow without a geometry -> corrective scroll -> geometry loop.
        }
        .onScrollPhaseChange { oldPhase, newPhase in
            let wasUserScrolling = oldPhase != .idle && oldPhase != .animating
            let isUserScrolling = newPhase != .idle && newPhase != .animating
            if isUserScrolling && !wasUserScrolling { onInteraction() }
            userIsScrolling = isUserScrolling
            if isUserScrolling {
                userHasScrolled = true
                didRestoreInitialViewport = true
            }
            if wasUserScrolling && !isUserScrolling {
                let finalViewport = readingViewport()
                followsLatest = finalViewport.isAtBottom
                viewportRecorder.lastUserViewport = finalViewport
                saveViewport(finalViewport)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // Once the person has left the end and is well above it, as on iPhone.
            let showsScrollToLatest = !followsLatest && farFromEnd
            ZStack {
                if showsScrollToLatest { scrollToLatestButton.transition(.opacity.combined(with: .scale(scale: 0.8))) }
            }
            // Only the button fades: animating the transcript with it would move its rows too.
            .animation(.easeOut(duration: 0.2), value: showsScrollToLatest)
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
        .onReceive(NotificationCenter.default.publisher(for: .revealTranscriptMessage)) { notification in
            guard let id = notification.object as? UUID, containsMessage(id) else { return }
            // The store already saved this position; an older checkpoint must not replace it.
            didRestoreInitialViewport = true
            viewportRecorder.lastUserViewport = nil
            followsLatest = id == lastMessageID
            Task { @MainActor in
                await Task.yield()
                if followsLatest { position.scrollTo(id: TranscriptScrollTarget.bottom, anchor: .bottom) }
                else { position.scrollTo(id: TranscriptScrollTarget.message(id), anchor: .top) }
            }
        }
        .onDisappear { saveLastUserViewport() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            saveLastUserViewport()
        }
        // Save the captured user checkpoint, never an outgoing view's resized
        // teardown geometry. This also covers switching chats during a gesture.
    }

    /// Above the composer, clear of the scroller.
    private var scrollToLatestButton: some View {
        Button(action: scrollToLatest) {
            Image(systemName: "chevron.down")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help("Scroll to Latest")
        .accessibilityLabel("Scroll to Latest")
        .padding(.trailing, 18)
        .padding(.bottom, bottomOverlayHeight + 10)
    }

    /// Back to the latest message, following new ones again.
    private func scrollToLatest() {
        onInteraction()
        didRestoreInitialViewport = true
        followsLatest = true
        let latest = TranscriptViewport(offset: viewportRecorder.viewport.offset, isAtBottom: true)
        viewportRecorder.lastUserViewport = latest
        saveViewport(latest)
        withAnimation { position.scrollTo(id: TranscriptScrollTarget.bottom, anchor: .bottom) }
    }

    private func readingViewport() -> TranscriptViewport {
        var viewport = viewportRecorder.viewport
        viewport.messageID = viewport.isAtBottom ? nil : position.viewID(type: TranscriptScrollTarget.self)?.messageID
        return viewport
    }

    private func saveLastUserViewport() {
        if let viewport = viewportRecorder.lastUserViewport { saveViewport(viewport) }
    }
}

/// Which messages a transcript holds, in every app: the newest page, or from where the reader last was, and a page
/// more each time the top is reached. Layout work for every update grows with the rows a transcript holds, not with
/// what is on screen. Later replies add to what shows rather than pushing the oldest rows out from under the reader.
enum TranscriptPaging {
    /// Messages shown when a conversation opens, and added each time the top is reached.
    static let pageSize = 100

    /// The index of the oldest message shown: from `firstShownID` once set, else the newest page and the reading position.
    static func firstShown(in messages: [ChatMessage], firstShownID: UUID?, reading: UUID?) -> Int {
        if let firstShownID, let index = messages.firstIndex(where: { $0.id == firstShownID }) { return index }
        let reading = reading.flatMap { id in messages.firstIndex { $0.id == id } }
        return min(max(messages.count - pageSize, 0), reading ?? .max)
    }

    /// The message to show from once the top is reached.
    static func pageBefore(_ first: Int, in messages: [ChatMessage]) -> UUID { messages[max(first - pageSize, 0)].id }
}

/// The row at the top of a transcript with older messages: reaching it shows the page before. Rows keep their place by ID.
struct TranscriptOlderPage: View {
    let first: Int
    let load: () -> Void

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            // Keyed by the first row, so a page too short to push it off screen still loads the next.
            .task(id: first, load)
    }
}

extension View {
    /// Holds a transcript's first shown message once it shows, and moves it back to show a message revealed above it.
    func transcriptPaging(firstShownID: Binding<UUID?>, shown: ArraySlice<ChatMessage>, all: [ChatMessage], first: Int) -> some View {
        onAppear { firstShownID.wrappedValue = firstShownID.wrappedValue ?? shown.first?.id }
            .onChange(of: shown.first?.id) { _, id in firstShownID.wrappedValue = firstShownID.wrappedValue ?? id }
            .onReceive(NotificationCenter.default.publisher(for: .revealTranscriptMessage)) { notification in
                guard let id = notification.object as? UUID, let index = all.firstIndex(where: { $0.id == id }),
                      index < first else { return }
                firstShownID.wrappedValue = id
            }
    }
}
