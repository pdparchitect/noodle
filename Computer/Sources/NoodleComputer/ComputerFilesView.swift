import AppKit
import ComputerCore
import QuickLook
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

struct ComputerFilesView: View {
    @StateObject private var model: ComputerFilesModel
    @State private var panelURL: URL?
    @State private var quickLookRequested = false
    @State private var naming: String?
    @State private var name = ""
    @State private var deleting = false
    @State private var path = ""
    @State private var enteringPath = false
    @State private var searching = false
    @State private var previewNotice: String?
    @State private var searchFocused = false
    @State private var fileFocusRequest = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var appearance: ComputerAppearance

    init(model: ComputerFilesModel, appearance: ComputerAppearance = .init()) {
        _model = StateObject(wrappedValue: model)
        self.appearance = appearance
    }
    var body: some View {
        observedContent
        .alert("File operation failed", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .alert("Preview unavailable", isPresented: Binding(get: { previewNotice != nil }, set: { if !$0 { previewNotice = nil } })) {
            Button("OK") { previewNotice = nil }
        } message: { Text(previewNotice ?? "") }
        .alert(naming ?? "Name", isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) { naming = nil }
            Button("Save") { if naming == "New Folder" { model.createFolder(name) } else { model.rename(name) }; naming = nil }
        }
        .alert("Go to Folder", isPresented: $enteringPath) {
            TextField("/workspace", text: $path)
            Button("Cancel", role: .cancel) {}
            Button("Go") { model.navigate(path) }
        } message: { Text("Enter a path inside this computer.") }
        .confirmationDialog(deleteTitle, isPresented: $deleting) {
            Button("Delete", role: .destructive) { model.removeSelected() }
        } message: { Text("This permanently removes the guest file or empty folder. Nonempty folders cannot be deleted here.") }
    }
    private var deleteTitle: String { "Delete \(model.selected?.name ?? "item")?" }
    private var fileContent: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                if model.previewEnabled { galleryPreview.frame(maxWidth: .infinity, maxHeight: .infinity) }
                VStack(spacing: 0) {
                    Group {
                        if model.iconView || model.previewEnabled { GuestFileGrid(model: model, quickLook: requestQuickLook, keyAction: keyboardAction, focusRequest: fileFocusRequest) }
                        else { GuestFileTable(model: model, quickLook: requestQuickLook, keyAction: keyboardAction, focusRequest: fileFocusRequest) }
                    }
                        .contextMenu {
                            Button("New Folder…") { name = "Untitled Folder"; naming = "New Folder" }.disabled(model.busy)
                            Button("Import Files or Folders…") { model.importPanel() }.disabled(model.busy)
                            Divider()
                            Button("Open Folder") { if let file = model.selected { model.open(file) } }.disabled(model.selected?.directory != true)
                            Button("Quick Look", action: requestQuickLook).disabled(model.selected?.regular != true)
                            Button("Export…") { model.exportPanel() }.disabled((model.selected?.regular != true && model.selected?.directory != true) || model.busy)
                            Divider()
                            Button("Rename…") { name = model.selected?.name ?? ""; naming = "Rename" }.disabled(model.selected == nil || model.busy)
                            Button("Duplicate") { model.duplicateSelected() }.disabled(model.selected?.regular != true || model.busy)
                            Button("Delete…", role: .destructive) { deleting = true }.disabled(model.selected == nil || model.busy)
                        }
                }.frame(minWidth: 260).frame(height: model.previewEnabled ? 150 : nil)

            }
            if model.busy || !model.status.isEmpty { transferStatus }
        }
    }
    private var transferStatus: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(model.status).font(.callout).lineLimit(1).truncationMode(.middle).help(model.status)
                    if model.busy {
                        ProgressView(value: model.transferProgress?.fraction)
                            .progressViewStyle(.linear)
                            .accessibilityLabel("Transfer progress")
                        if let progress = model.transferProgress {
                            Text("\(progress.completedItems) of \(progress.totalItems) items · \(ByteCountFormatter.string(fromByteCount: progress.transferredBytes, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: progress.totalBytes, countStyle: .file))")
                                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if model.busy {
                    Button("Cancel") { model.cancelTransfer() }.disabled(model.cancellingTransfer)
                        .help("Cancel this transfer")
                } else {
                    Button { model.status = "" } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).accessibilityLabel("Dismiss transfer status")
                }
            }.padding(12)
        }
    }
    private var observedContent: some View {
        fileContent
        .background(Color(computerColour(appearance.terminalBackground)).opacity(appearance.terminalOpacity))
        .toolbar { fileToolbar }
        .quickLookPreview($panelURL)
        .onChange(of: searching) { _, active in if !active { searchFocused = false; fileFocusRequest += 1 } }
        .onChange(of: model.previewURL) { _, url in
            if quickLookRequested, let url { panelURL = url; quickLookRequested = false }
            else if panelURL != nil { panelURL = url }
        }
        .onChange(of: model.previewEnabled) { _, enabled in if enabled { model.loadPreview() } else if panelURL == nil { model.stopPreview() } }
        .onChange(of: panelURL) { _, url in if url == nil, !model.previewEnabled { model.stopPreview() } }
        .onChange(of: model.previewStatus) { _, status in
            if quickLookRequested, status != "Loading preview…", model.previewURL == nil { previewNotice = status; quickLookRequested = false }
        }
        .onChange(of: model.selection) { _, _ in quickLookRequested = false }
        .task { model.navigate(model.folder, record: false) }
        .onDisappear { panelURL = nil; model.disappear() }
    }
    @ToolbarContentBuilder private var fileToolbar: some ToolbarContent {
        ToolbarItem(id: "files-navigation", placement: .automatic) {
            ControlGroup {
                Button { model.back() } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(model.history.isEmpty).help("Back (⌘[)")
                Button { model.forward() } label: { Label("Forward", systemImage: "chevron.right") }
                    .disabled(model.forwardHistory.isEmpty).help("Forward (⌘])")
            }
            .controlGroupStyle(.navigation)
            .labelStyle(.iconOnly)
        }
        ToolbarSpacer(.flexible, placement: .automatic)
        ToolbarItem(id: "files-layout", placement: .automatic) {
            Picker("File View", selection: Binding(
                get: { model.previewEnabled ? 2 : model.iconView ? 0 : 1 },
                set: { mode in
                    model.iconView = mode != 1
                    model.previewEnabled = mode == 2
                    if mode == 2, model.selected == nil { model.choose(model.visible.first) }
                }
            )) {
                Image(systemName: "square.grid.2x2").tag(0).accessibilityLabel("Icons").help("Icons")
                Image(systemName: "list.bullet").tag(1).accessibilityLabel("List").help("List")
                Image(systemName: "rectangle.bottomthird.inset.filled").tag(2).accessibilityLabel("Gallery").help("Gallery")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
        ToolbarItem(id: "files-actions", placement: .automatic) {
                Menu {
                    Button("New Folder…") { name = "Untitled Folder"; naming = "New Folder" }.disabled(model.busy)
                    Button("Import Files or Folders…") { model.importPanel() }.disabled(model.busy)
                    Button("Export…") { model.exportPanel() }.disabled((model.selected?.regular != true && model.selected?.directory != true) || model.busy)
                    Divider()
                    Button("Rename…") { name = model.selected?.name ?? ""; naming = "Rename" }.disabled(model.selected == nil || model.busy)
                    Button("Duplicate") { model.duplicateSelected() }.disabled(model.selected?.regular != true || model.busy)
                    Button("Delete…", role: .destructive) { deleting = true }.disabled(model.selected == nil || model.busy)
                    Divider()
                    Button("Go to Folder…") { path = model.folder; enteringPath = true }
                    Button("Enclosing Folder") { model.navigate(model.parent) }.disabled(model.folder == "/")
                    Button("Workspace") { model.navigate("/workspace") }
                    Button("Home") { model.navigate("/root") }
                    Button("Filesystem") { model.navigate("/") }
                    Divider()
                    Button("Refresh") { model.navigate(model.folder, record: false) }
                    Toggle("Show Hidden Files", isOn: $model.showHidden)
                } label: { Label("File Actions", systemImage: "ellipsis") }
                .menuIndicator(.hidden).help("File Actions")
        }
        ToolbarSpacer(.fixed, placement: .automatic)
        ToolbarItem(id: "files-search", placement: .automatic) {
            Group {
                if searching {
                    HStack(spacing: 7) {
                        Image(systemName: "magnifyingglass")
                        ComputerFileSearchField(text: $model.filter, focused: $searchFocused) {
                            searching = false; model.filter = ""
                        }.frame(minWidth: 0)
                        Button { searching = false; model.filter = "" } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.secondary)
                        }.help("Close Search")
                    }
                    .padding(.horizontal, 9)
                    .frame(minWidth: 120, idealWidth: 240, maxWidth: 240)
                    .frame(height: 34)
                    .overlay(Capsule().strokeBorder(.primary.opacity(searchFocused ? 0.4 : 0), lineWidth: 2))
                    .buttonStyle(.borderless)
                    .transition(.opacity)
                } else {
                    Button { openSearch() } label: {
                        Label("Search", systemImage: "magnifyingglass")
                    }.help("Search (⌘F)")
                    .transition(.opacity)
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: searching)
        }
    }
    @ViewBuilder private var galleryPreview: some View {
        if let file = model.selected {
            VStack(spacing: 12) {
                if let url = model.previewURL { NativeFilePreview(url: url).frame(maxWidth: .infinity, maxHeight: .infinity) }
                else {
                    Spacer()
                    Image(nsImage: GuestFileIcon.image(file)).resizable().scaledToFit().frame(width: 96, height: 96)
                    if model.previewStatus == "Loading preview…" { ProgressView().controlSize(.small) }
                    Spacer()
                }
                Text(file.displayName).font(.headline).lineLimit(1).truncationMode(.middle)
                Text(file.directory ? "Folder" : ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        } else { Color.clear }
    }
    private func openSearch() {
        if searching { searchFocused = true }
        else { searching = true }
    }
    private func keyboardAction(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if modifiers == .command {
            switch event.keyCode {
            case 125: if let file = model.selected { if file.directory { model.open(file) } else { requestQuickLook() } }; return true
            case 126: model.goUp(); return true
            default: break
            }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "[": model.back(); return true
            case "]": model.forward(); return true
            case "f": openSearch(); return true
            default: break
            }
        }
        if modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "g" {
            path = model.folder; enteringPath = true; return true
        }
        if modifiers.isEmpty {
            if event.keyCode == 49 { requestQuickLook(); return true }
            if event.keyCode == 36, let file = model.selected { name = file.name; naming = "Rename"; return true }
        }
        return false
    }
    private func requestQuickLook() {
        guard model.selected?.regular == true else { return }
        if let url = model.previewURL { panelURL = url }
        else {
            quickLookRequested = true
            model.loadPreview()
            if model.previewStatus != "Loading preview…" { previewNotice = model.previewStatus; quickLookRequested = false }
        }
    }
}

private struct NativeFilePreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact)!
        view.autostarts = false
        view.previewItem = url as NSURL
        return view
    }
    func updateNSView(_ view: QLPreviewView, context: Context) { if view.previewItem?.previewItemURL != url { view.previewItem = url as NSURL } }
    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) { view.close() }
}

private final class FilesTableView: NSTableView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    var keyAction: ((NSEvent) -> Bool)?
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, keyAction?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if keyAction?(event) != true { super.keyDown(with: event) }
    }
}

private struct GuestFileTable: NSViewRepresentable {
    @ObservedObject var model: ComputerFilesModel
    let quickLook: () -> Void
    let keyAction: (NSEvent) -> Bool
    let focusRequest: Int
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView {
        let table = FilesTableView()
        table.keyAction = keyAction
        table.delegate = context.coordinator; table.dataSource = context.coordinator
        context.coordinator.quickLook = quickLook
        table.target = context.coordinator; table.doubleAction = #selector(Coordinator.open)
        table.rowHeight = 30; table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = .clear
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (id, title, width) in [("name", "Name", 250.0), ("size", "Size", 85.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title; column.width = width; column.minWidth = id == "name" ? 140 : 75
            table.addTableColumn(column)
        }
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType(rawValue: $0) }
        table.registerForDraggedTypes([.fileURL, .init("com.pdparchitect.noodle.guest-file")] + promiseTypes)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setAccessibilityLabel("Computer files")
        let scroll = NSScrollView(); scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? FilesTableView else { return }
        let coordinator = context.coordinator
        coordinator.quickLook = quickLook
        table.keyAction = keyAction
        if coordinator.focusRequest != focusRequest {
            coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { [weak table] in if let table { table.window?.makeFirstResponder(table) } }
        }
        let items = model.visible
        if coordinator.items != items { coordinator.items = items; table.reloadData() }
        let index = items.firstIndex { $0.name == model.selection }
        if table.selectedRow != (index ?? -1) { table.selectRowIndexes(index.map { IndexSet(integer: $0) } ?? [], byExtendingSelection: false) }
    }
    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let model: ComputerFilesModel
        var items: [GuestFile] = []
        var focusRequest = 0
        var dragged: GuestFile?
        var draggedFolder: String?
        var dropFolder: String?
        var quickLook: (() -> Void)?
        init(model: ComputerFilesModel) { self.model = model }
        func numberOfRows(in tableView: NSTableView) -> Int { items.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let file = items[row]
            if tableColumn?.identifier.rawValue == "size" {
                let text = NSTextField(labelWithString: file.directory ? "—" : ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                text.font = .systemFont(ofSize: 12); text.textColor = .secondaryLabelColor
                text.translatesAutoresizingMaskIntoConstraints = false
                let cell = NSView(); cell.addSubview(text)
                NSLayoutConstraint.activate([
                    text.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                    text.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                    text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
                ])
                return cell
            }
            let image = NSImageView(image: GuestFileIcon.image(file))
            image.translatesAutoresizingMaskIntoConstraints = false
            image.widthAnchor.constraint(equalToConstant: 20).isActive = true
            image.heightAnchor.constraint(equalToConstant: 20).isActive = true
            image.setContentHuggingPriority(.required, for: .horizontal)
            let text = NSTextField(labelWithString: file.displayName)
            text.lineBreakMode = .byTruncatingMiddle; text.maximumNumberOfLines = 1; text.usesSingleLineMode = true
            text.toolTip = file.name
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let stack = NSStackView(views: [image, text]); stack.spacing = 8
            return stack
        }
        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let table = notification.object as? NSTableView else { return }
            let file = items.indices.contains(table.selectedRow) ? items[table.selectedRow] : nil
            if model.selection != file?.name { model.choose(file) }
        }
        @objc func open(_ table: NSTableView) { if items.indices.contains(table.clickedRow) { let file = items[table.clickedRow]; model.choose(file); if file.directory { model.open(file) } else { quickLook?() } } }
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard !model.busy else { return nil }
            let file = items[row]; dragged = file; draggedFolder = model.folder
            return FileExportPromise.provider(model: model, file: file)
        }
        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            dropFolder = nil
            guard !model.busy, !model.loading else { return [] }
            let local = (info.draggingSource as? NSTableView) === tableView
            if local { guard dragged != nil, draggedFolder == model.folder else { return [] } }
            else if !info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) { return [] }
            let dragOperation: NSDragOperation = local ? .move : .copy
            guard info.draggingSourceOperationMask.contains(dragOperation) else { return [] }
            let hit = tableView.row(at: tableView.convert(info.draggingLocation, from: nil))
            let hovered = items.indices.contains(hit) ? items[hit] : nil
            guard let folder = FileDropDestination.folder(model.folder, hovered: hovered, moving: local ? dragged : nil) else { return [] }
            dropFolder = folder
            tableView.setDropRow(hovered == nil ? -1 : hit, dropOperation: .on)
            return dragOperation
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            guard !model.busy, !model.loading, let folder = dropFolder else { return false }
            defer { dropFolder = nil }
            if (info.draggingSource as? NSTableView) === tableView {
                guard let dragged, draggedFolder == model.folder else { return false }
                model.move(dragged, intoFolder: folder); return true
            }
            guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
            model.importFiles(urls, into: folder); return true
        }
    }
}

@MainActor final class FileExportPromise: NSObject, NSFilePromiseProviderDelegate {
    static func provider(model: ComputerFilesModel, file: GuestFile) -> NSFilePromiseProvider? {
        guard file.regular || file.directory, let path = try? GuestFile.path(model.folder, file.name) else { return nil }
        let delegate = FileExportPromise(model: model, file: file, path: path)
        let type = file.directory ? UTType.folder : UTType(filenameExtension: (file.name as NSString).pathExtension) ?? .data
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: delegate)
        provider.userInfo = delegate
        return provider
    }
    private static let queue: OperationQueue = {
        let queue = OperationQueue(); queue.name = "Noodle File Exports"; queue.maxConcurrentOperationCount = 1; return queue
    }()
    let model: ComputerFilesModel
    let file: GuestFile
    let path: String
    init(model: ComputerFilesModel, file: GuestFile, path: String) { self.model = model; self.file = file; self.path = path }
    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { Self.queue }
    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String { file.name }
    nonisolated func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping ((any Error)?) -> Void) {
        Task { @MainActor in
            model.promisedExport(file, path: path, to: url, completion: completionHandler)
        }
    }
}
