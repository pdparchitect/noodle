import AppKit
import Carbon.HIToolbox
import SwiftUI
import Observation
import NoodleCore

struct AgentPickerItem: Identifiable, Equatable {
    enum Direction { case left, right, up, down }
    let id: UUID
    let title: String
    let lastActivity: Date
    /// Already open as a floating window.
    let isFloating: Bool
    var hasUnread = false

    var accessibilityValue: String {
        [hasUnread ? "Unread" : nil, isFloating ? "Floating" : nil].compactMap { $0 }.joined(separator: ", ")
    }

    @MainActor static func items(in store: NoodleStore, floating: Set<UUID>) -> [Self] {
        store.conversations.map {
            Self(id: $0.id, title: store.title(for: $0), lastActivity: $0.updatedAt, isFloating: floating.contains($0.id),
                hasUnread: store.hasUnreadMessages(in: $0))
        }
    }

    /// Open floats come first, so the grid doubles as a switcher between them.
    static func visible(_ items: [Self], filter: String) -> [Self] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        return items.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
            .sorted { $0.isFloating != $1.isFloating ? $0.isFloating : $0.lastActivity > $1.lastActivity }
    }

    /// A move that would leave the grid keeps the selection where it is.
    static func move(_ index: Int, by direction: Direction, count: Int, columns: Int) -> Int {
        let target: Int
        switch direction {
        case .left: target = index - 1
        case .right: target = index + 1
        case .up: target = index - columns
        case .down: target = index + columns
        }
        return (0..<count).contains(target) ? target : index
    }
}

/// The panel is exactly as tall as its rows, up to three; more rows scroll.
enum AgentPickerLayout {
    static let columns = 4
    static let width: CGFloat = 560
    static let tileHeight: CGFloat = 104
    static let spacing: CGFloat = 10
    static let maximumRows = 3
    static let padding: CGFloat = 18
    static let searchHeight: CGFloat = 24
    static let sectionSpacing: CGFloat = 14
    private static let gridInset: CGFloat = 2

    static func gridHeight(items: Int) -> CGFloat {
        let rows = CGFloat(min(max((items + columns - 1) / columns, 1), maximumRows))
        return rows * tileHeight + (rows - 1) * spacing + 2 * gridInset
    }

    /// Rows that fit never scroll, so the grid cannot rubber-band as it appears.
    static func scrolls(items: Int) -> Bool { items > columns * maximumRows }

    static func height(items: Int) -> CGFloat {
        padding + searchHeight + sectionSpacing + 1 + sectionSpacing + gridHeight(items: items) + padding
    }

    /// Hangs from the top edge, so the search field opens in the same place however many rows follow.
    static func frame(_ frame: NSRect, items: Int) -> NSRect {
        let height = height(items: items)
        return NSRect(x: frame.minX, y: frame.maxY - height, width: width, height: height)
    }
}

@MainActor @Observable final class AgentPickerModel {
    static let columns = AgentPickerLayout.columns
    private(set) var items: [AgentPickerItem] = []
    var filter = "" { didSet { selection = 0 } }
    var selection = 0
    var visible: [AgentPickerItem] { AgentPickerItem.visible(items, filter: filter) }
    /// Chosen once when the panel opens. Resizing while filtering moves the window
    /// and its content a frame apart, which reads as a wobble.
    var height: CGFloat { AgentPickerLayout.height(items: items.count) }
    var gridHeight: CGFloat { AgentPickerLayout.gridHeight(items: items.count) }

    func present(_ items: [AgentPickerItem]) {
        self.items = items
        filter = ""
        selection = 0
    }

    func move(_ direction: AgentPickerItem.Direction) {
        selection = AgentPickerItem.move(selection, by: direction, count: visible.count, columns: Self.columns)
    }
}

/// A system-wide shortcut. Carbon hot keys need no Input Monitoring permission
/// and are allowed in the sandbox.
@MainActor final class GlobalHotKey {
    private static var actions: [UInt32: @MainActor () -> Void] = [:]
    private static var handler: EventHandlerRef?
    private var ref: EventHotKeyRef?
    private let id: UInt32

    init?(keyCode: Int, modifiers: Int, id: UInt32, action: @escaping @MainActor () -> Void) {
        self.id = id
        if Self.handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
                var hotKey = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKey)
                let id = hotKey.id
                DispatchQueue.main.async { MainActor.assumeIsolated { GlobalHotKey.actions[id]?() } }
                return noErr
            }, 1, &spec, nil, &Self.handler)
        }
        let signature = OSType(0x4e_44_4c_45) // NDLE
        guard RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), EventHotKeyID(signature: signature, id: id),
            GetEventDispatcherTarget(), 0, &ref) == noErr else { return nil }
        Self.actions[id] = action
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
        Self.actions[id] = nil
    }

    static func modifiers(for modifiers: KeyBinding.Modifiers) -> Int {
        var carbon = 0
        if modifiers.contains(.command) { carbon |= cmdKey }
        if modifiers.contains(.shift) { carbon |= shiftKey }
        if modifiers.contains(.option) { carbon |= optionKey }
        if modifiers.contains(.control) { carbon |= controlKey }
        return carbon
    }

    /// Carbon registers a physical key, so a letter is looked up in the current keyboard layout.
    static func keyCode(for key: String) -> Int? {
        let fixed: [String: Int] = [" ": kVK_Space, "\r": kVK_Return, "\t": kVK_Tab, "\u{8}": kVK_Delete, "\u{1b}": kVK_Escape]
        if let code = fixed[key] { return code }
        return (0..<128).first { character(for: $0) == key }
    }

    static func character(for keyCode: Int) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeys: UInt32 = 0, length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { bytes in
            UCKeyTranslate(bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress, UInt16(keyCode), UInt16(kUCKeyActionDown), 0,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters)
        }
        guard status == noErr, length == 1 else { return nil }
        return String(utf16CodeUnits: characters, count: 1).lowercased()
    }
}

/// The grid of conversations summoned over any app. Picking one lands it as a
/// floating conversation window.
@MainActor final class AgentPickerController: NSObject, NSWindowDelegate {
    static let shared = AgentPickerController()
    private let model = AgentPickerModel()
    private var panel: AgentPickerPanel?
    private var hotKey: GlobalHotKey?

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(self, selector: #selector(showRequested), name: .floatConversation, object: nil)
        registerHotKey()
    }

    /// Follows Settings > Keybindings. The hot key is released while a shortcut is
    /// being recorded, or the recorder would never see the current combination.
    private func registerHotKey() {
        hotKey?.unregister(); hotKey = nil
        let bindings = KeyboardBindings.shared
        let binding = withObservationTracking {
            bindings.recordingAction == nil ? bindings.binding(for: .chooseConversation) : nil
        } onChange: { [weak self] in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.registerHotKey() } }
        }
        guard let binding, let keyCode = GlobalHotKey.keyCode(for: binding.key) else { return }
        hotKey = GlobalHotKey(keyCode: keyCode, modifiers: GlobalHotKey.modifiers(for: binding.modifiers), id: 1) { [weak self] in self?.toggle() }
        if hotKey == nil { NSLog("Could not register the agent picker shortcut %@", binding.displayName) }
    }

    @objc private func showRequested() { show() }

    func toggle() {
        if panel?.isVisible == true { close() } else { show() }
    }

    func show() {
        guard let store = NoodleStore.active, store.storageReady else { return }
        FloatingConversations.shared.retain(Set(store.conversations.map(\.id)))
        model.present(AgentPickerItem.items(in: store, floating: FloatingConversationPanels.shared.openIDs))
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // A fresh view is laid out for these items before it is shown, so no frame of the previous grid appears.
        let content = NSHostingView(rootView: AgentPickerView(model: model, pick: { [weak self] in self?.pick($0) })
            .environment(store).preferredColorScheme(.dark))
        content.sizingOptions = []
        panel.contentView = content
        let point = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            // Anchor the top edge, so the search field appears in the same place however many rows follow.
            let top = visible.minY + visible.height * 0.72
            panel.setFrame(AgentPickerLayout.frame(NSRect(x: visible.midX - AgentPickerLayout.width / 2, y: top, width: AgentPickerLayout.width, height: 0),
                items: model.items.count), display: false)
        }
        content.layoutSubtreeIfNeeded()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() { panel?.orderOut(nil) }

    private func pick(_ id: UUID) {
        close()
        NoodleStore.active?.floatConversation(id)
    }

    private func pickSelection() {
        let visible = model.visible
        guard visible.indices.contains(model.selection) else { return }
        pick(visible[model.selection].id)
    }

    private func makePanel() -> AgentPickerPanel {
        let panel = AgentPickerPanel(contentRect: NSRect(x: 0, y: 0, width: AgentPickerLayout.width, height: AgentPickerLayout.height(items: 1)),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.title = "Conversations"
        panel.level = .modalPanel
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.delegate = self
        panel.onKey = { [weak self] key in
            guard let self else { return }
            switch key {
            case .move(let direction): model.move(direction)
            case .pick: pickSelection()
            case .cancel: close()
            }
        }
        return panel
    }

    func windowDidResignKey(_ notification: Notification) { close() }
}

private final class AgentPickerPanel: NSPanel {
    enum Key { case move(AgentPickerItem.Direction), pick, cancel }
    var onKey: ((Key) -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onKey?(.cancel) }

    // The filter field is first responder, so grid keys are taken before it sees them.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.modifierFlags.intersection([.command, .option, .control]).isEmpty {
            switch Int(event.keyCode) {
            case kVK_LeftArrow: onKey?(.move(.left)); return
            case kVK_RightArrow: onKey?(.move(.right)); return
            case kVK_UpArrow: onKey?(.move(.up)); return
            case kVK_DownArrow: onKey?(.move(.down)); return
            case kVK_Return, kVK_ANSI_KeypadEnter: onKey?(.pick); return
            case kVK_Escape: onKey?(.cancel); return
            default: break
            }
        }
        super.sendEvent(event)
    }
}

private struct AgentPickerView: View {
    @Environment(NoodleStore.self) private var store
    @Bindable var model: AgentPickerModel
    let pick: (UUID) -> Void
    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(spacing: AgentPickerLayout.sectionSpacing) {
            TextField("Search", text: $model.filter)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .focused($filterFocused)
                .padding(.horizontal, 6)
                .frame(height: AgentPickerLayout.searchHeight)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: AgentPickerLayout.spacing), count: AgentPickerModel.columns),
                              spacing: AgentPickerLayout.spacing) {
                        ForEach(Array(model.visible.enumerated()), id: \.element.id) { index, item in
                            tile(item, selected: index == model.selection)
                                .id(item.id)
                                .onTapGesture { pick(item.id) }
                        }
                    }
                    .padding(2)
                }
                .frame(height: model.gridHeight, alignment: .top)
                .scrollDisabled(!AgentPickerLayout.scrolls(items: model.visible.count))
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(.never)
                .onChange(of: model.selection) { _, selection in
                    let visible = model.visible
                    guard AgentPickerLayout.scrolls(items: visible.count), visible.indices.contains(selection) else { return }
                    proxy.scrollTo(visible[selection].id)
                }
            }
            .overlay {
                if model.visible.isEmpty {
                    Text("No Conversations").foregroundStyle(.secondary)
                }
            }
        }
        .padding(AgentPickerLayout.padding)
        .frame(width: AgentPickerLayout.width, height: model.height, alignment: .top)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onAppear { filterFocused = true }
    }

    @ViewBuilder private func tile(_ item: AgentPickerItem, selected: Bool) -> some View {
        let conversation = store.conversations.first { $0.id == item.id }
        VStack(spacing: 8) {
            ConversationAvatar(participants: conversation.map { store.participants(for: $0) } ?? [],
                isGroup: conversation?.kind == .group, size: 56)
                .overlay(alignment: .topTrailing) {
                    if item.isFloating {
                        Image(systemName: "pip.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Color.accentColor, in: Circle())
                            .offset(x: 6, y: -4)
                            .help("Floating")
                    }
                }
            HStack(spacing: 5) {
                if item.hasUnread {
                    // The sidebar's unread dot.
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 8, height: 8)
                        .help("Unread")
                }
                Text(item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .frame(height: AgentPickerLayout.tileHeight)
        .background(selected ? Color.accentColor.opacity(0.28) : Color.white.opacity(0.04),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.accessibilityValue)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}
