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
    @FocusState private var searchFocused: Bool
    @State private var fileFocusRequest = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var appearance: ComputerAppearance

    init(model: ComputerFilesModel, appearance: ComputerAppearance = .init()) {
        _model = StateObject(wrappedValue: model)
        self.appearance = appearance
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                HStack(spacing: 0) {
                    Button { model.back() } label: { Image(systemName: "chevron.left").frame(width: 34, height: 32) }
                        .disabled(model.history.isEmpty).help("Back (⌘[)")
                    Rectangle().fill(.primary.opacity(0.12)).frame(width: 1, height: 16)
                    Button { model.forward() } label: { Image(systemName: "chevron.right").frame(width: 34, height: 32) }
                        .disabled(model.forwardHistory.isEmpty).help("Forward (⌘])")
                }.background(.primary.opacity(0.025), in: Capsule())
                    .overlay(Capsule().strokeBorder(.primary.opacity(0.13), lineWidth: 1))
                Button { path = model.folder; enteringPath = true } label: {
                    Text(model.folder == "/" ? "Filesystem" : (model.folder as NSString).lastPathComponent)
                        .font(.headline).lineLimit(1).truncationMode(.middle)
                }.help("Go to Folder")
                Spacer(minLength: 8)
                HStack(spacing: 2) {
                    viewButton("square.grid.2x2", title: "Icons", selected: model.iconView && !model.previewEnabled) {
                        model.iconView = true; model.previewEnabled = false
                    }
                    viewButton("list.bullet", title: "List", selected: !model.iconView && !model.previewEnabled) {
                        model.iconView = false; model.previewEnabled = false
                    }
                    viewButton("rectangle.bottomthird.inset.filled", title: "Gallery", selected: model.previewEnabled) {
                        model.previewEnabled = true
                        if model.selected == nil { model.choose(model.visible.first) }
                    }
                }.padding(3).background(.primary.opacity(0.025), in: Capsule())
                    .overlay(Capsule().strokeBorder(.primary.opacity(0.13), lineWidth: 1))
                if model.busy {
                    ProgressView().controlSize(.small).help(model.status)
                    Button { model.cancelTransfer() } label: { Image(systemName: "xmark.circle") }.help("Cancel Transfer")
                }
                Menu {
                    Button("New Folder…") { name = "Untitled Folder"; naming = "New Folder" }.disabled(model.busy)
                    Button("Import Files…") { model.importPanel() }.disabled(model.busy)
                    Button("Export…") { model.exportPanel() }.disabled(model.selected?.regular != true || model.busy)
                    Divider()
                    Button("Rename…") { name = model.selected?.name ?? ""; naming = "Rename" }.disabled(model.selected == nil || model.busy)
                    Button("Duplicate") { model.duplicateSelected() }.disabled(model.selected?.regular != true || model.busy)
                    Button("Delete…", role: .destructive) { deleting = true }.disabled(model.selected == nil || model.busy)
                    Divider()
                    Button("Enclosing Folder") { model.navigate(model.parent) }.disabled(model.folder == "/")
                    Button("Workspace") { model.navigate("/workspace") }
                    Button("Home") { model.navigate("/root") }
                    Button("Filesystem") { model.navigate("/") }
                    Divider()
                    Button("Refresh") { model.navigate(model.folder, record: false) }
                    Toggle("Show Hidden Files", isOn: $model.showHidden)
                } label: { Image(systemName: "ellipsis").font(.system(size: 16)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .frame(width: 42, height: 34).contentShape(Capsule())
                    .background(.primary.opacity(0.025), in: Capsule())
                    .overlay(Capsule().strokeBorder(.primary.opacity(0.13), lineWidth: 1)).help("File Actions")
                HStack(spacing: 7) {
                    Button { searching = true; searchFocused = true } label: {
                        Image(systemName: "magnifyingglass").font(.system(size: 15))
                            .frame(width: 16, height: 24)
                    }.help("Search (⌘F)")
                    if searching {
                        TextField("Search", text: $model.filter).textFieldStyle(.plain)
                            .focused($searchFocused).frame(minWidth: 0)
                            .onExitCommand { searching = false; model.filter = "" }
                            .transition(.opacity)
                        Button { searching = false; model.filter = "" } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 13)).foregroundStyle(.secondary)
                        }.help("Close Search").transition(.opacity)
                    }
                }.padding(.horizontal, 9)
                    .frame(minWidth: searching ? 120 : 34, idealWidth: searching ? 240 : 34, maxWidth: searching ? 240 : 34)
                    .frame(height: 34)
                    .background(.primary.opacity(searching ? 0.06 : 0.025), in: Capsule())
                    .overlay(Capsule().strokeBorder(.primary.opacity(searchFocused ? 0.4 : 0.13), lineWidth: searchFocused ? 2 : 1))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: searching)

            }.buttonStyle(.borderless).padding(.horizontal, 18).padding(.vertical, 12)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: searching)
            VStack(spacing: 0) {
                if model.previewEnabled { galleryPreview.frame(maxWidth: .infinity, maxHeight: .infinity) }
                VStack(spacing: 0) {
                    Group {
                        if model.iconView || model.previewEnabled { GuestFileGrid(model: model, quickLook: requestQuickLook, keyAction: keyboardAction, focusRequest: fileFocusRequest) }
                        else { GuestFileTable(model: model, quickLook: requestQuickLook, keyAction: keyboardAction, focusRequest: fileFocusRequest) }
                    }
                        .contextMenu {
                            Button("New Folder…") { name = "Untitled Folder"; naming = "New Folder" }.disabled(model.busy)
                            Button("Import Files…") { model.importPanel() }.disabled(model.busy)
                            Divider()
                            Button("Open Folder") { if let file = model.selected { model.open(file) } }.disabled(model.selected?.directory != true)
                            Button("Quick Look", action: requestQuickLook).disabled(model.selected?.regular != true)
                            Button("Export…") { model.exportPanel() }.disabled(model.selected?.regular != true || model.busy)
                            Divider()
                            Button("Rename…") { name = model.selected?.name ?? ""; naming = "Rename" }.disabled(model.selected == nil || model.busy)
                            Button("Duplicate") { model.duplicateSelected() }.disabled(model.selected?.regular != true || model.busy)
                            Button("Delete…", role: .destructive) { deleting = true }.disabled(model.selected == nil || model.busy)
                        }
                }.frame(minWidth: 260).frame(height: model.previewEnabled ? 150 : nil)

            }
        }
        .background(Color(computerColour(appearance.terminalBackground)).opacity(appearance.terminalOpacity))
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
        .confirmationDialog("Delete \(model.selected?.name ?? "item")?", isPresented: $deleting) {
            Button("Delete", role: .destructive) { model.removeSelected() }
        } message: { Text("This permanently removes the guest file or empty folder. Nonempty folders cannot be deleted here.") }
    }
    private func viewButton(_ symbol: String, title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 16)).frame(width: 32, height: 28)
                .background(selected ? Color.primary.opacity(0.16) : .clear, in: Capsule()) }
            .accessibilityLabel(title).help(title)
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
            case "f": searching = true; searchFocused = true; return true
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
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
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
            let file = items[row]; dragged = file
            if file.directory {
                let item = NSPasteboardItem(); item.setString(file.name, forType: .init("com.pdparchitect.noodle.guest-file")); return item
            }
            guard file.regular, let path = try? GuestFile.path(model.folder, file.name) else { return nil }
            let delegate = FileExportPromise(model: model, file: file, path: path)
            let provider = NSFilePromiseProvider(fileType: UTType(filenameExtension: (file.name as NSString).pathExtension)?.identifier ?? UTType.data.identifier, delegate: delegate)
            provider.userInfo = delegate
            return provider
        }
        func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
            guard !model.busy else { return [] }
            if (info.draggingSource as? NSTableView) === tableView {
                guard items.indices.contains(row), items[row].directory, dragged?.name != items[row].name else { return [] }
                tableView.setDropRow(row, dropOperation: .on); return .move
            }
            tableView.setDropRow(-1, dropOperation: .on)
            return info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
        }
        func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
            if (info.draggingSource as? NSTableView) === tableView {
                guard let dragged, items.indices.contains(row) else { return false }
                model.move(dragged, into: items[row]); return true
            }
            guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
            model.importFiles(urls); return true
        }
    }
}

@MainActor final class FileExportPromise: NSObject, NSFilePromiseProviderDelegate {
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
