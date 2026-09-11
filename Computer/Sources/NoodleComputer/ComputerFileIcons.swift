import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor enum GuestFileIcon {
    static func image(_ file: GuestFile) -> NSImage {
        // Ask macOS for its native artwork using type metadata only. This does
        // not read guest bytes or start document thumbnail generators.
        if file.directory { return NSWorkspace.shared.icon(for: .folder) }
        if file.kind == "symlink" { return NSImage(systemSymbolName: "link", accessibilityDescription: "Symbolic link")! }
        let type = UTType(filenameExtension: (file.name as NSString).pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}

private final class FileIconItem: NSCollectionViewItem {
    private let icon = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    override func loadView() {
        view = NSView(); view.wantsLayer = true; view.layer?.cornerRadius = 8
        icon.imageScaling = .scaleProportionallyUpOrDown
        caption.alignment = .center; caption.maximumNumberOfLines = 1; caption.usesSingleLineMode = true
        caption.lineBreakMode = .byTruncatingMiddle; caption.font = .systemFont(ofSize: 12)
        for child in [icon, caption] { child.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(child) }
        NSLayoutConstraint.activate([
            icon.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            icon.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            icon.widthAnchor.constraint(equalToConstant: 64), icon.heightAnchor.constraint(equalToConstant: 64),
            caption.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 6),
            caption.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 3),
            caption.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -3)
        ])
    }
    func configure(_ file: GuestFile) {
        _ = view
        icon.image = GuestFileIcon.image(file); caption.stringValue = file.displayName; view.toolTip = file.name
        view.setAccessibilityElement(true); view.setAccessibilityRole(.button)
        view.setAccessibilityLabel(file.name); view.setAccessibilityHelp(file.directory ? "Folder" : "File")
        updateSelection()
    }
    override var isSelected: Bool { didSet { updateSelection() } }
    private func updateSelection() {
        view.layer?.backgroundColor = isSelected ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.35).cgColor : NSColor.clear.cgColor
        caption.textColor = .labelColor
    }
}

private final class FileIconCollection: NSCollectionView {
    var quickLook: (() -> Void)?
    var keyAction: ((NSEvent) -> Bool)?
    var selectIndex: ((Int) -> Void)?
    var names: [String] = []
    private var typed = ""
    private var typedAt = Date.distantPast
    override var acceptsFirstResponder: Bool { true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    var doubleClick: ((IndexPath) -> Void)?
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
        if event.clickCount == 2, let path = indexPathForItem(at: convert(event.locationInWindow, from: nil)) { doubleClick?(path) }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, keyAction?(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if keyAction?(event) == true { return }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        guard modifiers.isEmpty, !names.isEmpty else { super.keyDown(with: event); return }
        let current = selectionIndexPaths.first?.item
        var target: Int?
        if (123...126).contains(event.keyCode) {
            let layout = collectionViewLayout as? NSCollectionViewFlowLayout
            let width = layout?.itemSize.width ?? 112
            let gap = layout?.minimumInteritemSpacing ?? 12
            let inset = (layout?.sectionInset.left ?? 18) + (layout?.sectionInset.right ?? 18)
            let columns = max(1, Int((bounds.width - inset + gap) / (width + gap)))
            let delta = event.keyCode == 123 ? -1 : event.keyCode == 124 ? 1 : event.keyCode == 125 ? columns : -columns
            target = current.map { min(names.count - 1, max(0, $0 + delta)) } ?? 0
            typed = ""
        } else if let characters = event.characters, !characters.isEmpty,
                  characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.value < 0xF700 }) {
            if Date().timeIntervalSince(typedAt) > 1 { typed = "" }
            typed += characters; typedAt = Date()
            target = names.firstIndex { $0.lowercased().hasPrefix(typed.lowercased()) }
        }
        if let target {
            let paths: Set<IndexPath> = [IndexPath(item: target, section: 0)]
            selectionIndexPaths = paths; selectIndex?(target)
            scrollToItems(at: paths, scrollPosition: .nearestVerticalEdge)
        } else { super.keyDown(with: event) }
    }

}

struct GuestFileGrid: NSViewRepresentable {
    @ObservedObject var model: ComputerFilesModel
    let quickLook: () -> Void
    let keyAction: (NSEvent) -> Bool
    let focusRequest: Int
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> NSScrollView {
        let collection = FileIconCollection()
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 112, height: 112)
        layout.minimumInteritemSpacing = 12; layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        collection.collectionViewLayout = layout
        collection.register(FileIconItem.self, forItemWithIdentifier: .init("file"))
        collection.isSelectable = true; collection.allowsMultipleSelection = false
        collection.backgroundColors = [.clear]
        collection.dataSource = context.coordinator; collection.delegate = context.coordinator
        collection.quickLook = quickLook
        collection.keyAction = keyAction
        collection.setAccessibilityLabel("Computer files")
        let promiseTypes = NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType(rawValue: $0) }
        collection.registerForDraggedTypes([.fileURL, .init("com.pdparchitect.noodle.guest-file")] + promiseTypes)
        collection.setDraggingSourceOperationMask(.copy, forLocal: false)
        collection.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        let coordinator = context.coordinator
        collection.selectIndex = { index in
            guard coordinator.items.indices.contains(index) else { return }
            coordinator.model.choose(coordinator.items[index])
        }
        collection.doubleClick = { [weak collection] path in
            guard coordinator.items.indices.contains(path.item) else { return }
            let file = coordinator.items[path.item]
            coordinator.model.choose(file)
            if file.directory { coordinator.model.open(file) } else { collection?.quickLook?() }
        }
        let scroll = NSScrollView(); scroll.documentView = collection; scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let collection = scroll.documentView as? FileIconCollection else { return }
        collection.quickLook = quickLook
        collection.keyAction = keyAction
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { [weak collection] in if let collection { collection.window?.makeFirstResponder(collection) } }
        }
        let items = model.visible
        collection.names = items.map(\.name)
        if context.coordinator.items != items { context.coordinator.items = items; collection.reloadData() }
        let selection = items.firstIndex { $0.name == model.selection }.map { Set([IndexPath(item: $0, section: 0)]) } ?? []
        if collection.selectionIndexPaths != selection { collection.selectionIndexPaths = selection }
    }
    @MainActor final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        let model: ComputerFilesModel
        var items: [GuestFile] = []
        var focusRequest = 0
        private var dragged: GuestFile?
        init(model: ComputerFilesModel) { self.model = model }
        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int { items.count }
        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: .init("file"), for: indexPath) as! FileIconItem
            item.configure(items[indexPath.item]); return item
        }
        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            if let path = indexPaths.first, items.indices.contains(path.item) { model.choose(items[path.item]) }
        }
        func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
            if collectionView.selectionIndexPaths.isEmpty { model.choose(nil) }
        }
        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> (any NSPasteboardWriting)? {
            guard !model.busy else { return nil }
            let file = items[indexPath.item]; dragged = file
            if file.directory {
                let item = NSPasteboardItem(); item.setString(file.name, forType: .init("com.pdparchitect.noodle.guest-file")); return item
            }
            guard file.regular, let path = try? GuestFile.path(model.folder, file.name) else { return nil }
            let delegate = FileExportPromise(model: model, file: file, path: path)
            let provider = NSFilePromiseProvider(fileType: UTType(filenameExtension: (file.name as NSString).pathExtension)?.identifier ?? UTType.data.identifier, delegate: delegate)
            provider.userInfo = delegate
            return provider
        }
        func collectionView(_ collectionView: NSCollectionView, validateDrop draggingInfo: any NSDraggingInfo,
                            proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>, dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
            guard !model.busy else { return [] }
            let index = proposedIndexPath.pointee.item
            if (draggingInfo.draggingSource as? NSCollectionView) === collectionView {
                guard items.indices.contains(index), items[index].directory, dragged?.name != items[index].name else { return [] }
                dropOperation.pointee = .on; return .move
            }
            return draggingInfo.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
        }
        func collectionView(_ collectionView: NSCollectionView, acceptDrop draggingInfo: any NSDraggingInfo, indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation) -> Bool {
            if (draggingInfo.draggingSource as? NSCollectionView) === collectionView {
                guard let dragged, items.indices.contains(indexPath.item) else { return false }
                model.move(dragged, into: items[indexPath.item]); return true
            }
            guard let urls = draggingInfo.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty else { return false }
            model.importFiles(urls); return true
        }
    }
}
