import HubLink
import NoodleCore
import NoodleRuntime
import NoodleRuntimeSettings
import NoodleWallpaper
import SwiftUI
import UniformTypeIdentifiers

extension EnvironmentValues {
    /// False in a column other than the focused one; true wherever a conversation is shown alone.
    @Entry var isFocusedColumn = true
}

/// View > As List shows one conversation beside the sidebar; As Columns shows several side by side.
enum MainWindowLayout: String {
    case list, columns
    static let key = "NoodleMainWindowLayout"
}

/// Which conversations are open as columns, per space, and which has focus.
@MainActor @Observable final class ColumnsModel {
    /// Kept across launches, so each space comes back with the columns it was left with.
    private var openBySpace: [String: [UUID]] = ColumnsModel.saved() {
        didSet { UserDefaults.standard.set(openBySpace.mapValues { $0.map(\.uuidString) }, forKey: Self.key) }
    }
    static let key = "NoodleOpenColumns"

    private static func saved() -> [String: [UUID]] {
        let stored = UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
        return stored.mapValues { $0.compactMap(UUID.init(uuidString:)) }
    }

    var focusedID: UUID?
    var scrollTarget: UUID?
    /// The toolbar's height, which the columns reach under.
    var topInset: CGFloat = 0
    /// A column whose input should take the keyboard, kept until that column exists to take it.
    var composerFocusTarget: (id: UUID, token: UUID)?

    func focusComposer(of id: UUID) { composerFocusTarget = (id, UUID()) }

    func open(in space: String?) -> [UUID] { openBySpace[space ?? ""] ?? [] }

    func show(_ id: UUID, in space: String?) {
        var ids = open(in: space)
        if !ids.contains(id) { ids.append(id) }
        openBySpace[space ?? ""] = ids
        focusedID = id
        scrollTarget = id
    }

    func close(_ id: UUID, in space: String?) -> UUID? {
        var ids = open(in: space)
        guard let index = ids.firstIndex(of: id) else { return focusedID }
        ids.remove(at: index)
        openBySpace[space ?? ""] = ids
        if focusedID == id { focusedID = ids.isEmpty ? nil : ids[min(index, ids.count - 1)] }
        return focusedID
    }

    func move(_ id: UUID, before target: UUID, in space: String?) {
        var ids = open(in: space)
        guard id != target, let from = ids.firstIndex(of: id) else { return }
        ids.remove(at: from)
        ids.insert(id, at: ids.firstIndex(of: target) ?? ids.endIndex)
        openBySpace[space ?? ""] = ids
    }

    /// Switching to a space closes the columns it does not hold, and returns the conversation to select there.
    func enter(_ space: String?, selected: UUID?, holds: (UUID) -> Bool) -> UUID? {
        let ids = open(in: space).filter(holds)
        if ids != open(in: space) { openBySpace[space ?? ""] = ids }
        if let focused = ids.first { return focused }
        // A space with no columns starts with the selected conversation, if it holds it, or with none.
        guard let selected, holds(selected) else {
            focusedID = nil
            return nil
        }
        show(selected, in: space)
        return selected
    }

    func step(_ offset: Int, in space: String?) -> UUID? {
        let ids = open(in: space)
        guard !ids.isEmpty else { return nil }
        let index = focusedID.flatMap { ids.firstIndex(of: $0) } ?? 0
        return ids[(index + offset + ids.count) % ids.count]
    }
}

struct ConversationColumns: View {
    @Environment(NoodleStore.self) private var store
    @Bindable var model: ColumnsModel
    static let minimumWidth: CGFloat = 360
    /// Columns this far past either edge load their transcript. Loaded columns stay loaded, since
    /// loading costs far more than keeping one, until more than maxLoaded are; the farthest then become cards.
    static let loadedMargin = 1, maxLoaded = 12
    @State private var visible = 0..<0
    @State private var loaded: Set<Int> = []

    var body: some View {
        // A saved column whose conversation has since gone is left out.
        let ids = model.open(in: store.space).filter { store.conversation(withID: $0) != nil }
        // The columns reach under the toolbar, so each wallpaper fills the window's height;
        // their contents start below it.
        GeometryReader { proxy in
            ColumnsScrollView(store: store, model: model, ids: ids, loaded: loaded) { visible = $0 }
            .ignoresSafeArea(.container, edges: .top)
            .onChange(of: proxy.safeAreaInsets.top, initial: true) { _, top in
                if model.topInset != top { model.topInset = top }
            }
        }
        .onChange(of: visible, initial: true) { updateLoaded(count: ids.count) }
        // A conversation chosen in the sidebar opens as a column, or scrolls to the one already open.
        .onChange(of: store.selectedConversationID, initial: true) { _, id in
            guard let id else { return }
            model.show(id, in: store.space)
            if NSApp.currentEventIsClick { model.focusComposer(of: id) }
        }
        .onChange(of: store.space) { _, space in
            store.selectedConversationID = model.enter(space, selected: store.selectedConversationID, holds: store.spaceHolds)
        }
        .onChange(of: ids, initial: true) { updateLoaded(count: ids.count) }
        .overlay {
            if ids.isEmpty {
                ContentUnavailableView("No Columns", systemImage: "rectangle.split.3x1",
                    description: Text("Choose a conversation to open it as a column."))
            }
        }
        // Stand-ins for the menu shortcuts the PRD asks for.
        .background {
            Group {
                Button("") { close(model.focusedID) }.keyboardShortcut("w", modifiers: [.command, .shift])
                Button("") { focus(model.step(-1, in: store.space)) }.keyboardShortcut("[", modifiers: .command)
                Button("") { focus(model.step(1, in: store.space)) }.keyboardShortcut("]", modifiers: .command)
            }
            .opacity(0).accessibilityHidden(true)
        }
    }

    private func updateLoaded(count: Int) {
        let next = Self.loadedColumns(loaded, visible: visible, count: count)
        if next != loaded { loaded = next }
    }

    /// The columns to keep loaded, by index, when `visible` are on screen out of `count`.
    static func loadedColumns(_ loaded: Set<Int>, visible: Range<Int>, count: Int) -> Set<Int> {
        // `visible` can still describe columns that were just closed, past the end of the ones left.
        let start = min(max(0, visible.lowerBound - loadedMargin), count)
        let near = Set(start..<max(start, min(count, visible.upperBound + loadedMargin)))
        var next = loaded.filter { $0 < count }.union(near)
        if next.count > maxLoaded {
            let center = Double(visible.lowerBound + visible.upperBound) / 2
            next = Set(next.sorted { abs(Double($0) - center) < abs(Double($1) - center) }.prefix(maxLoaded))
        }
        return next
    }


    private func close(_ id: UUID?) {
        guard let id else { return }
        store.selectedConversationID = model.close(id, in: store.space)
    }

    private func focus(_ id: UUID?) {
        guard let id else { return }
        model.show(id, in: store.space)
        store.selectedConversationID = id
    }
}

/// The columns in an AppKit scroll view. Scrolling moves only the clip view's bounds, so a column's
/// SwiftUI graph is not laid out again for every scrolled point, as it is inside a SwiftUI ScrollView.
private struct ColumnsScrollView: NSViewRepresentable {
    let store: NoodleStore
    let model: ColumnsModel
    let ids: [UUID]
    let loaded: Set<Int>
    let visibleChanged: (Range<Int>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = SidewaysScrollView()
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        // The columns place their contents below the toolbar themselves.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = FlippedView()
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.scrollView = scrollView
        // Transcripts would reflow at every step of a drag of the window's edge; they take the new width once it ends.
        scrollView.liveResizeChanged = { [coordinator = context.coordinator] resizing in
            coordinator.frozenWidth = resizing ? coordinator.width : nil
            if !resizing { coordinator.layout() }
        }
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.boundsChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.boundsChanged),
            name: NSView.frameDidChangeNotification, object: scrollView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.layout()
        if let target = model.scrollTarget, let index = ids.firstIndex(of: target) {
            DispatchQueue.main.async { model.scrollTarget = nil }
            coordinator.reveal(index)
        }
    }

    @MainActor final class Coordinator: NSObject {
        var parent: ColumnsScrollView?
        weak var scrollView: NSScrollView?
        private var columns: [UUID: NSHostingView<AnyView>] = [:]
        private var shown: [UUID: Bool] = [:]
        private var lastVisible = 0..<0

        /// The width the columns had when a live resize began; they keep it until it ends.
        var frozenWidth: CGFloat?

        /// Columns share the area, each at most half of it, until they reach their minimum; past that,
        /// as many as fit whole share it, so the visible ones always meet both edges.
        var width: CGFloat {
            if let frozenWidth { return frozenWidth }
            guard let scrollView, let parent else { return ConversationColumns.minimumWidth }
            let available = scrollView.contentView.bounds.width
            let fitting = max(1, Int(available / ConversationColumns.minimumWidth))
            // Before the area has a size, available is zero.
            return max(ConversationColumns.minimumWidth, available / CGFloat(min(max(parent.ids.count, 2), fitting)))
        }

        func layout() {
            guard let parent, let scrollView, let document = scrollView.documentView else { return }
            let width = width, height = scrollView.contentView.bounds.height
            document.frame = NSRect(x: 0, y: 0, width: width * CGFloat(parent.ids.count), height: height)
            for id in Set(columns.keys).subtracting(parent.ids) {
                columns.removeValue(forKey: id)?.removeFromSuperview()
                shown[id] = nil
            }
            for (index, id) in parent.ids.enumerated() {
                let isLoaded = parent.loaded.contains(index)
                let content = AnyView(ColumnSlot(conversationID: id, model: parent.model, isLoaded: isLoaded).environment(parent.store))
                let view: NSHostingView<AnyView>
                if let existing = columns[id] {
                    view = existing
                    if shown[id] != isLoaded { view.rootView = content }
                } else {
                    view = NSHostingView(rootView: content)
                    view.sizingOptions = []
                    view.safeAreaRegions = []
                    document.addSubview(view)
                    columns[id] = view
                }
                shown[id] = isLoaded
                // On whole pixels: a column at a fractional position draws its text and pictures blurred.
                let frame = document.backingAlignedRect(NSRect(x: CGFloat(index) * width, y: 0, width: width, height: height),
                    options: .alignAllEdgesNearest)
                if view.frame != frame { view.frame = frame }
            }
            boundsChanged()
        }

        @objc func boundsChanged() {
            guard let scrollView, let parent else { return }
            let bounds = scrollView.contentView.bounds, width = width
            if scrollView.documentView?.frame.height != bounds.height || abs((scrollView.documentView?.frame.width ?? 0) - width * CGFloat(parent.ids.count)) > 0.5 {
                // The area was resized: columns take their new widths.
                DispatchQueue.main.async { self.layout() }
                return
            }
            let first = max(0, Int(bounds.minX / width))
            let last = min(parent.ids.count, Int((bounds.maxX / width).rounded(.up)))
            let visible = first..<max(first, last)
            if visible != lastVisible {
                lastVisible = visible
                let report = parent.visibleChanged
                DispatchQueue.main.async { report(visible) }
            }
        }

        func reveal(_ index: Int) {
            guard let scrollView else { return }
            let width = width, bounds = scrollView.contentView.bounds
            let minX = CGFloat(index) * width
            var x = bounds.minX
            if minX < bounds.minX { x = minX } else if minX + width > bounds.maxX { x = minX + width - bounds.width }
            guard x != bounds.minX else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                context.allowsImplicitAnimation = true
                scrollView.contentView.animator().setBoundsOrigin(NSPoint(x: x, y: 0))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    /// Each column's transcript scrolls vertically and would take every swipe over it. A swipe that
    /// starts mostly sideways goes to the columns instead, with its momentum.
    private final class SidewaysScrollView: NSScrollView {
        private var monitor: Any?
        private var routing = false
        var liveResizeChanged: ((Bool) -> Void)?

        override func viewWillStartLiveResize() {
            super.viewWillStartLiveResize()
            liveResizeChanged?(true)
        }

        override func viewDidEndLiveResize() {
            super.viewDidEndLiveResize()
            liveResizeChanged?(false)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.route(event) else { return event }
                return nil
            }
        }

        private func route(_ event: NSEvent) -> Bool {
            guard event.window === window else { return false }
            let isWheel = event.phase.isEmpty && event.momentumPhase.isEmpty
            if event.phase == .began || isWheel {
                let inside = bounds.contains(convert(event.locationInWindow, from: nil))
                routing = inside && abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            }
            guard routing else { return false }
            scrollWheel(with: event)
            if isWheel { routing = false }
            return true
        }
    }
}

/// Each column has a SwiftUI graph of its own, so an update in one column leaves the others alone.
private struct ColumnSlot: View {
    @Environment(NoodleStore.self) private var store
    let conversationID: UUID
    let model: ColumnsModel
    let isLoaded: Bool

    var body: some View {
        if let conversation = store.conversation(withID: conversationID) {
            ConversationColumn(conversation: conversation, model: model, isLoaded: isLoaded)
        }
    }
}

private struct ConversationColumn: View {
    @Environment(NoodleStore.self) private var store
    let conversation: BotConversation
    @Bindable var model: ColumnsModel
    let isLoaded: Bool
    @State private var kickRequest: AgentKickRequest?
    @State private var isDropTargeted = false
    @State private var isReorderTargeted = false
    @State private var composerFocusRequest: UUID?

    private var isFocused: Bool { model.focusedID == conversation.id }

    /// Clicking into another column also starts typing in it; clicks in the focused one keep their own meaning.
    private func select() {
        let switching = model.focusedID != conversation.id
        model.focusedID = conversation.id
        if store.selectedConversationID != conversation.id { store.selectedConversationID = conversation.id }
        if switching { model.focusComposer(of: conversation.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ColumnHeader(conversation: conversation, isFocused: isFocused, kickRequest: $kickRequest,
                select: { select(); model.focusComposer(of: conversation.id) },
                reorder: .init(targeted: { isReorderTargeted = $0 }, drop: { id in
                    withAnimation(.smooth) { model.move(id, before: conversation.id, in: store.space) }
                })) {
                store.selectedConversationID = model.close(conversation.id, in: store.space)
            }
            // The header's bar reaches up under the app's toolbar. Only the bar is drawn there: clicks
            // pass through to the toolbar, which keeps moving and zooming the window.
            .padding(.top, model.topInset)
            .background {
                // A thin frost keeps the wallpaper's colour; the focused column's band is lighter, the others' darker.
                ZStack {
                    Rectangle().fill(.ultraThinMaterial)
                    Rectangle().fill(isFocused ? Color.white.opacity(0.14) : Color.black.opacity(0.28))
                }
                .animation(.smooth(duration: 0.2), value: isFocused)
                .allowsHitTesting(false)
            }

            if isLoaded {
                AttachmentPreviewScope(conversationID: conversation.id) { preview in
                    ChatView(conversation: conversation, attachmentPreview: preview, composerFocusRequest: composerFocusRequest)
                        .environment(\.isFocusedColumn, isFocused)
                }
            } else {
                ColumnCard(conversation: conversation)
            }
        }
        .background {
            let background = store.background(for: conversation)
            ConversationWallpaper(background: background,
                imageURL: store.repository.backgroundImageURL(background, conversationID: conversation.id))
                .allowsHitTesting(false)
        }
        .clipped()
        .overlay(alignment: .trailing) {
            Rectangle().fill(.separator).frame(width: 1).accessibilityHidden(true)
        }
        .overlay(alignment: .leading) {
            if isReorderTargeted {
                Rectangle().fill(Color.accentColor).frame(width: 3).allowsHitTesting(false)
            }
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.accentColor, lineWidth: 2).padding(4)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .simultaneousGesture(TapGesture().onEnded(select))
        .onDrop(of: AttachmentTransfer.dropContentTypes, isTargeted: $isDropTargeted) { providers in
            guard !providers.isEmpty else { return false }
            store.markConversationRead(conversation.id)
            store.importAttachments(from: providers, into: conversation.id)
            return true
        }
        .modifier(AgentKickConfirmation(store: store, request: $kickRequest))
        .onChange(of: model.composerFocusTarget?.token, initial: true) {
            guard let target = model.composerFocusTarget, target.id == conversation.id else { return }
            model.composerFocusTarget = nil
            DispatchQueue.main.async { composerFocusRequest = UUID() }
        }
    }
}

/// What a column far off screen shows instead of its transcript.
private struct ColumnCard: View {
    @Environment(NoodleStore.self) private var store
    let conversation: BotConversation

    var body: some View {
        VStack(spacing: 10) {
            ConversationStatusAvatar(conversation: conversation, size: 56, dotSize: 12, ringWidth: 3)
            Text(store.title(for: conversation)).font(.title3.weight(.semibold))
            Text(store.preview(for: conversation))
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).lineLimit(4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ColumnHeader: View {
    @Environment(NoodleStore.self) private var store
    let conversation: BotConversation
    let isFocused: Bool
    @Binding var kickRequest: AgentKickRequest?
    let select: () -> Void
    let reorder: ColumnDragHandle.Reorder
    let close: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                ConversationStatusAvatar(conversation: conversation, size: 26, dotSize: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.title(for: conversation))
                        .font(.headline)
                        .lineLimit(1)
                    Text(store.preview(for: conversation))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
            }
            .overlay { ColumnDragHandle(id: conversation.id, select: select, reorder: reorder) }
            editButton
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            ConversationPauseControl(conversation: conversation, kickRequest: $kickRequest)
            Group {
                VoiceCallToolbarControl(conversation: conversation)
                ConversationCompanionsMenu(conversation: conversation)
                Button(action: close) { Label("Close Column", systemImage: "xmark") }
                    .help("Close Column")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
                .accessibilityHidden(true)
        }
        .onHover { isHovered = $0 }
    }

    @ViewBuilder private var editButton: some View {
        if conversation.kind == .direct, let agent = store.participants(for: conversation).first, !store.isShared(agent.id) {
            Button { store.agentBeingEdited = agent } label: {
                Label("Edit Bot", systemImage: "pencil")
            }
            .help("Edit Bot")
        } else if conversation.kind == .group {
            Button { store.groupBeingEdited = conversation } label: {
                Label("Group Info", systemImage: "pencil")
            }
            .help("Group Info")
        }
    }
}

/// View > Enter Full Screen, in place of the one AppKit appends right after the layouts.
struct FullScreenCommand: View {
    @State private var state = FullScreenState()

    var body: some View {
        Button(state.isFullScreen ? "Exit Full Screen" : "Enter Full Screen") {
            NSApp.keyWindow?.toggleFullScreen(nil)
        }
        .keyboardShortcut("f", modifiers: [.control, .command])
    }
}

@MainActor @Observable private final class FullScreenState {
    var isFullScreen = false
    @ObservationIgnored private var observers: [Any] = []

    init() {
        let update: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated { self.isFullScreen = NSApp.keyWindow?.styleMask.contains(.fullScreen) == true }
        }
        for name in [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification, NSWindow.didBecomeKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main, using: update))
        }
    }
}

/// View > As List and As Columns.
struct MainWindowLayoutCommands: View {
    @AppStorage(MainWindowLayout.key) private var layout = MainWindowLayout.list

    var body: some View {
        Picker("Layout", selection: $layout) {
            Text("As List").tag(MainWindowLayout.list)
            Text("As Columns").tag(MainWindowLayout.columns)
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

/// View › Sidebar: how the sidebar shows bots and groups, the line under each name, and their order.
struct SidebarCommands: View {
    @AppStorage(ConversationListStyle.key) private var style = ConversationListStyle.standard.rawValue
    @AppStorage(ConversationRowDetail.key) private var detail = ConversationRowDetail.standard.rawValue
    @AppStorage(ConversationOrder.key) private var order = ConversationOrder.standard.rawValue

    var body: some View {
        Menu("Sidebar") {
            Picker("Style", selection: $style) {
                ForEach(ConversationListStyle.allCases) { Text($0.name).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Picker("Line", selection: $detail) {
                ForEach(ConversationRowDetail.allCases) { Text("Show \($0.name)").tag($0.rawValue) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
            Divider()
            Picker("Order", selection: $order) {
                ForEach(ConversationOrder.allCases) { Text($0.name).tag($0.rawValue) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
    }
}

/// View › Conversation: how a conversation lays out attachments and long messages.
struct ConversationLayoutCommands: View {
    @AppStorage(ChatAttachmentLayout.defaultsKey) private var attachmentLayout = ChatAttachmentLayout.defaultValue.rawValue
    @AppStorage(MessageTextLayout.defaultsKey) private var textLayout = MessageTextLayout.defaultValue.rawValue

    var body: some View {
        Menu("Conversation") {
            // Toggles, not inline pickers: a picker brings its own separators, which put a line
            // between each section's header and its items.
            Section("Attachments") {
                ForEach(ChatAttachmentLayout.allCases) { layout in
                    Toggle(layout.displayName, isOn: choice(layout.rawValue, in: $attachmentLayout)).help(layout.explanation)
                }
            }
            Section("Long Messages") {
                ForEach(MessageTextLayout.allCases) { layout in
                    Toggle(layout.displayName, isOn: choice(layout.rawValue, in: $textLayout)).help(layout.explanation)
                }
            }
        }
    }

    /// On while `value` is chosen; choosing it again leaves it chosen.
    private func choice(_ value: String, in selection: Binding<String>) -> Binding<Bool> {
        Binding(get: { selection.wrappedValue == value }, set: { if $0 { selection.wrappedValue = value } })
    }
}

/// The open columns as pictures in the toolbar; choosing one brings its column into view.
struct ColumnSwitcher: View {
    @Environment(NoodleStore.self) private var store
    let model: ColumnsModel

    var body: some View {
        let conversations = model.open(in: store.space).compactMap(store.conversation(withID:))
        if !conversations.isEmpty {
            HStack(spacing: 4) {
                ForEach(conversations) { conversation in
                    let isFocused = model.focusedID == conversation.id
                    Button {
                        store.selectedConversationID = conversation.id
                        model.focusComposer(of: conversation.id)
                    } label: {
                        ConversationStatusAvatar(conversation: conversation, size: 24, dotSize: 7)
                            .padding(3)
                            .background(Circle().fill(isFocused ? Color.accentColor.opacity(0.35) : .clear))
                    }
                    .buttonStyle(.plain)
                    .help(store.title(for: conversation))
                    .accessibilityLabel(store.title(for: conversation))
                    .accessibilityAddTraits(isFocused ? .isSelected : [])
                }
            }
            .padding(.horizontal, 6)
        }
    }
}

/// Pressing a column's header selects it, and dragging moves it, from the first press: SwiftUI's
/// draggable lost the press to the focus change when another column had the keyboard.
struct ColumnDragHandle: NSViewRepresentable {
    /// Only Noodle's own type, so a column dropped on a transcript or a message field is not taken as text.
    static let type = NSPasteboard.PasteboardType("com.pdparchitect.noodle.column")
    let id: UUID
    let select: () -> Void
    let reorder: Reorder

    /// Another column dropped here goes before this one.
    struct Reorder {
        let targeted: (Bool) -> Void
        let drop: (UUID) -> Void
    }

    func makeNSView(context: Context) -> HandleView {
        let view = HandleView()
        view.registerForDraggedTypes([Self.type])
        return view
    }

    func updateNSView(_ view: HandleView, context: Context) {
        view.id = id
        view.select = select
        view.reorder = reorder
    }

    final class HandleView: NSView, NSDraggingSource {
        var id: UUID?
        var select: (() -> Void)?
        var reorder: Reorder?
        private var press: NSEvent?

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            reorder?.targeted(true)
            return .move
        }

        override func draggingExited(_ sender: NSDraggingInfo?) { reorder?.targeted(false) }

        override func draggingEnded(_ sender: NSDraggingInfo) { reorder?.targeted(false) }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            reorder?.targeted(false)
            guard let id = sender.draggingPasteboard.string(forType: ColumnDragHandle.type).flatMap(UUID.init(uuidString:)) else { return false }
            reorder?.drop(id)
            return true
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func mouseDown(with event: NSEvent) { press = event }

        override func mouseUp(with event: NSEvent) {
            guard press != nil else { return }
            press = nil
            select?()
        }

        override func mouseDragged(with event: NSEvent) {
            guard let press, let id, let window, let content = window.contentView else { return }
            self.press = nil
            let item = NSPasteboardItem()
            item.setString(id.uuidString, forType: ColumnDragHandle.type)
            let dragging = NSDraggingItem(pasteboardWriter: item)
            // The header as it looks, taken from the window, since this view draws nothing itself.
            let rect = content.convert(bounds, from: self)
            let image = NSImage(size: bounds.size)
            if let rep = content.bitmapImageRepForCachingDisplay(in: rect) {
                content.cacheDisplay(in: rect, to: rep)
                image.addRepresentation(rep)
            }
            dragging.setDraggingFrame(bounds, contents: image)
            beginDraggingSession(with: [dragging], event: press, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? .move : []
        }
    }
}
