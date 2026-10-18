import AppKit
import NoodleCore
import NoodleRuntimeSettings
import SwiftUI

extension ConversationAttachment {
    /// A `.patch` or `.diff` file. It opens in a review when it reads as a patch, and in Quick Look when it does not.
    var isPatchFile: Bool {
        annotation == nil && url == nil && voice == nil && Patch.isPatchFile(name: originalFilename, mediaType: mediaType)
    }
}

// MARK: - Card

/// The picture on a patch's card: its commits and who made them, and the files that changed most.
struct PatchCardPicture: View {
    let patch: Patch
    let filename: String
    static let shown = 6

    var body: some View {
        let files = patch.largestFiles(Self.shown)
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 9, weight: .semibold))
                Text(patch.headline(filename: filename)).font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if patch.commits.count > 1 {
                    Text("\(patch.commits.count) commits").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1).background(Color.accentColor, in: Capsule())
                }
            }
            .foregroundStyle(.secondary).padding(.bottom, 2)
            ForEach(Array(files)) { file in
                HStack(spacing: 5) {
                    Text(file.name).font(.system(size: 9.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    PatchChangeCounts(added: file.added, removed: file.removed, size: 9)
                }
            }
            if patch.fileCount > Self.shown {
                Text("+ \(patch.fileCount - Self.shown) more").font(.system(size: 9)).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// "+148 −49", in green and red.
struct PatchChangeCounts: View {
    let added: Int
    let removed: Int
    var size: CGFloat = 11
    var dimmed = false

    var body: some View {
        HStack(spacing: 5) {
            Text("+\(added)").foregroundStyle(dimmed ? AnyShapeStyle(HierarchicalShapeStyle.secondary) : AnyShapeStyle(Color.green))
            Text(removed > 0 ? "−\(removed)" : "").foregroundStyle(dimmed ? AnyShapeStyle(HierarchicalShapeStyle.secondary) : AnyShapeStyle(Color.red))
                .frame(minWidth: size * 3, alignment: .leading)
        }
        .font(.system(size: size, design: .monospaced)).monospacedDigit()
    }
}

// MARK: - Window

/// Patches open for review, each in a window of its own in the frame of the other previews.
@MainActor final class PatchReviewWindows: NSObject, NSWindowDelegate {
    @MainActor private final class Review {
        let panel: PatchReviewPanel
        let model: PatchReviewModel
        let fileURL: URL
        /// The editor every other preview comments with.
        let editor = AttachmentPreviewController()
        weak var host: NSWindow?

        init(panel: PatchReviewPanel, model: PatchReviewModel, fileURL: URL, host: NSWindow?) {
            self.panel = panel; self.model = model; self.fileURL = fileURL; self.host = host
        }
    }

    private var reviews: [UUID: Review] = [:]

    /// The review in front, if one is open.
    var frontmost: NSWindow? {
        let open = reviews.values.map(\.panel)
        return NSApp.orderedWindows.first { window in open.contains { $0 === window } } ?? open.first
    }

    func model(for attachment: ConversationAttachment) -> PatchReviewModel? { reviews[attachment.id]?.model }

    /// Opens the review of `attachment`, or brings it forward. `frame` is in screen coordinates.
    func open(_ attachment: ConversationAttachment, patch: Patch, store: NoodleStore, frame: NSRect? = nil) {
        if let review = reviews[attachment.id] {
            if let frame { review.panel.setFrame(frame, display: true) }
            return review.panel.makeKeyAndOrderFront(nil)
        }
        let host = NSApp.keyWindow
        let panel = PatchReviewPanel(contentRect: NSRect(x: 0, y: 0, width: 880, height: 900),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        panel.identifier = NSUserInterfaceItemIdentifier("NoodlePatchReview")
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.minSize = NSSize(width: 560, height: 360)
        let title = patch.title(filename: attachment.originalFilename)
        panel.title = title
        let model = PatchReviewModel(patch: patch, attachment: attachment, viewed: store.viewedPatchFiles(attachment)) { [weak store] in
            store?.saveViewedPatchFiles($0, for: attachment)
        }
        let content = NSHostingView(rootView: PatchReviewView(model: model, store: store).environment(\.colorScheme, .dark))
        content.sizingOptions = []
        let share = NSButton(image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Share")!,
                             target: self, action: #selector(share(_:)))
        share.isBordered = false; share.contentTintColor = .secondaryLabelColor; share.toolTip = "Share"
        panel.contentView = AnnotationPreviewFrame(content: content, filename: title,
            kindLabel: patch.commits.isEmpty ? "Diff" : "Patch", accessory: share)
        if let frame {
            panel.setFrame(frame, display: false)
        } else {
            let screen = host?.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? panel.frame
            var frame = panel.frame
            frame.size.width = min(frame.width, screen.width)
            frame.size.height = min(frame.height, screen.height)
            frame.origin = NSPoint(x: screen.midX - frame.width / 2, y: screen.midY - frame.height / 2)
            panel.setFrame(frame, display: false)
        }
        let review = Review(panel: panel, model: model, fileURL: store.attachmentFileURL(attachment), host: host)
        panel.annotate = { [weak self, weak review, weak store] in
            guard let self, let review, let store else { return }
            self.annotate(review, store: store)
        }
        panel.clearSelection = { [weak model] in
            guard let model, model.selection != nil else { return false }
            model.selection = nil
            return true
        }
        panel.delegate = self
        reviews[attachment.id] = review
        panel.makeKeyAndOrderFront(nil)
    }

    /// Comments on the selected lines with the editor and annotation of every other preview, so the
    /// note waits in the composer and reaches the bot as any other does.
    private func annotate(_ review: Review, store: NoodleStore) {
        guard !review.editor.hasPendingAnnotation, let quote = review.model.selectedQuote else { NSSound.beep(); return }
        review.editor.annotateConversation(in: review.panel, source: review.model.attachment, quote: quote) { [weak store] note, content, source in
            guard let store else { throw WorkspaceError.missingConversation(source.conversationID) }
            try store.saveAnnotation(note, content: content, source: source)
        }
    }

    @objc private func share(_ sender: NSButton) {
        guard let review = reviews.values.first(where: { $0.panel === sender.window }) else { return }
        NSSharingServicePicker(items: [review.fileURL]).show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSPanel,
              let id = reviews.first(where: { $0.value.panel === closing })?.key, let review = reviews[id] else { return }
        reviews[id] = nil
        review.editor.close()
        closing.contentView = nil
        if closing.isKeyWindow { review.host?.makeKeyAndOrderFront(nil) }
    }
}

private final class PatchReviewPanel: NSPanel {
    var annotate: (() -> Void)?
    /// Escape first lets go of selected lines; true when there were some.
    var clearSelection: (() -> Bool)?

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) {
        if clearSelection?() != true { close() }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if KeyboardBindings.shared.matches(.annotateSelection, event: event) {
            if !event.isARepeat { annotate?() }
            return true
        }
        if event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           event.charactersIgnoringModifiers == "w" { close(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

// MARK: - Review

/// Where someone is in a review: what they ticked off, opened and selected.
@MainActor @Observable final class PatchReviewModel {
    /// Lines of one hunk, from where the selection started to where it ends.
    struct Selection: Equatable {
        var path: String
        var hunk: Int
        var anchor: Int
        var head: Int
        var lines: ClosedRange<Int> { min(anchor, head)...max(anchor, head) }
    }

    /// How many hunks of a file show before the rest are asked for.
    static let hunksShown = 3

    let patch: Patch
    let attachment: ConversationAttachment
    private(set) var viewed: Set<String>
    var expanded: Set<String>
    var everyHunk: Set<String> = []
    var selection: Selection?
    var filter = ""
    var hidesViewed = false
    var showsWalkthrough = true
    private let save: (Set<String>) -> Void

    init(patch: Patch, attachment: ConversationAttachment, viewed: Set<String>, save: @escaping (Set<String>) -> Void) {
        self.patch = patch; self.attachment = attachment; self.viewed = viewed; self.save = save
        // A patch of one file opens on it.
        expanded = patch.files.count == 1 ? Set(patch.files.map(\.path)).subtracting(viewed) : []
    }

    /// Ticked files fold away.
    func setViewed(_ path: String, _ isViewed: Bool) {
        if isViewed {
            viewed.insert(path)
            expanded.remove(path)
            if selection?.path == path { selection = nil }
        } else {
            viewed.remove(path)
        }
        save(viewed)
    }

    func toggle(_ path: String) {
        if expanded.remove(path) == nil { expanded.insert(path) }
    }

    /// A click selects a line, or lets go of it; a Shift-click extends the selection within its hunk.
    func select(path: String, hunk: Int, line: Int, extending: Bool) {
        if extending, var selection, selection.path == path, selection.hunk == hunk {
            selection.head = line
            self.selection = selection
        } else if selection == Selection(path: path, hunk: hunk, anchor: line, head: line) {
            selection = nil
        } else {
            selection = Selection(path: path, hunk: hunk, anchor: line, head: line)
        }
    }

    func isSelected(path: String, hunk: Int, line: Int) -> Bool {
        guard let selection, selection.path == path, selection.hunk == hunk else { return false }
        return selection.lines.contains(line)
    }

    /// What a comment on the selected lines quotes.
    var selectedQuote: String? {
        guard let selection, let file = patch.files.first(where: { $0.path == selection.path }),
              file.hunks.indices.contains(selection.hunk) else { return nil }
        let lines = file.hunks[selection.hunk].lines
        guard lines.indices.contains(selection.lines.lowerBound), lines.indices.contains(selection.lines.upperBound) else { return nil }
        return Patch.quote(Array(lines[selection.lines]), in: file.path)
    }
}

/// A patch: what it changes, the walkthrough of its commits, and every file to tick off.
struct PatchReviewView: View {
    @Bindable var model: PatchReviewModel
    let store: NoodleStore
    @State private var walkthroughHeight: CGFloat = 0

    private struct Comment {
        var hunk: Int
        var line: Int
        var text: String
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            progress
            Divider()
            files
        }
        // Solid rather than the frame's glass: code is read here at length.
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.patch.summary).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            if !model.patch.commits.isEmpty { walkthrough.padding(.top, 6) }
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var walkthrough: some View {
        let commits = model.patch.commits
        return VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(.easeOut(duration: 0.15)) { model.showsWalkthrough.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(model.showsWalkthrough ? 90 : 0)).frame(width: 12)
                    Text("Walkthrough · \(commits.count) \(commits.count == 1 ? "step" : "steps")")
                        .font(.system(size: 12, weight: .semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if model.showsWalkthrough {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(commits.enumerated()), id: \.offset) { index, commit in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(index + 1)").font(.system(size: 11, weight: .semibold)).monospacedDigit()
                                    .foregroundStyle(.secondary).frame(width: 12, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                                        Text(commit.subject).font(.system(size: 12, weight: .medium))
                                        if let sha = commit.shortSHA {
                                            Text(sha).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                                        }
                                    }
                                    if let note = commit.flowingNote {
                                        Text(note).font(.system(size: 11.5)).foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.leading, 2).padding(.bottom, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { walkthroughHeight = $0 }
                }
                // A long series scrolls in place, so the files stay in reach.
                .frame(height: min(max(walkthroughHeight, 20), 220))
            }
        }
    }

    // MARK: Progress and filter

    private var progress: some View {
        let files = model.patch.files
        let viewed = files.filter { model.viewed.contains($0.path) }.count
        return HStack(spacing: 10) {
            Text("\(viewed) of \(files.count) viewed").font(.system(size: 12, weight: .semibold)).monospacedDigit()
            ProgressView(value: Double(viewed), total: Double(max(files.count, 1)))
                .progressViewStyle(.linear).controlSize(.small).frame(width: 140)
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Filter files", text: $model.filter).textFieldStyle(.plain).font(.system(size: 11.5))
            }
            .padding(.horizontal, 8).padding(.vertical, 4).frame(width: 190)
            .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
            Toggle("Hide viewed", isOn: $model.hidesViewed).toggleStyle(.button).controlSize(.small)
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
    }

    // MARK: Files

    private enum Row: Identifiable {
        case folder(String, viewed: Int, total: Int)
        case file(Patch.File, comments: Int)
        case hunk(Patch.File, Int)
        case line(Patch.File, hunk: Int, line: Int)
        case comment(String, id: String)
        case note(String, id: String)
        case more(Patch.File, Int)
        case empty(String)

        var id: String {
            switch self {
            case .folder(let folder, _, _): "folder:\(folder)"
            case .file(let file, _): "file:\(file.path)"
            case .hunk(let file, let hunk): "hunk:\(file.path):\(hunk)"
            case .line(let file, let hunk, let line): "line:\(file.path):\(hunk):\(line)"
            case .comment(_, let id), .note(_, let id): id
            case .more(let file, _): "more:\(file.path)"
            case .empty: "empty"
            }
        }
    }

    private var files: some View {
        let rows = rows(comments: comments)
        let hint = KeyboardBindings.shared.binding(for: .annotateSelection)
            .map { "Click a line to select it, Shift-click to select more, then press \($0.displayName) to comment" }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    view(for: row, hint: hint)
                }
            }
            .padding(.bottom, 12)
        }
    }

    /// Comments on this patch, sent or still in the composer, by file, under the lines they quote.
    private var comments: [String: [Comment]] {
        let notes = (store.attachmentsByConversation[model.attachment.conversationID] ?? [])
            .compactMap(\.annotation).filter { $0.sourceAttachmentID == model.attachment.id }
        var placed: [String: [Comment]] = [:]
        for note in notes {
            guard let quote = note.quote, let place = model.patch.place(of: quote) else { continue }
            placed[place.path, default: []].append(Comment(hunk: place.hunk, line: place.line, text: note.comment))
        }
        return placed
    }

    private func rows(comments: [String: [Comment]]) -> [Row] {
        let patch = model.patch
        let shown = patch.files.filter { file in
            (model.filter.isEmpty || file.path.localizedCaseInsensitiveContains(model.filter)) &&
                !(model.hidesViewed && model.viewed.contains(file.path))
        }
        let everyFolder = Dictionary(grouping: patch.files, by: \.folder)
        let folders = Dictionary(grouping: shown, by: \.folder)
        var rows: [Row] = []
        for folder in folders.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let all = everyFolder[folder] ?? []
            rows.append(.folder(folder, viewed: all.filter { model.viewed.contains($0.path) }.count, total: all.count))
            for file in folders[folder] ?? [] {
                let notes = comments[file.path] ?? []
                rows.append(.file(file, comments: notes.count))
                if model.expanded.contains(file.path) { rows += content(of: file, comments: notes) }
            }
        }
        if shown.isEmpty {
            rows.append(.empty(model.filter.isEmpty ? "Every file is viewed." : "No file matches “\(model.filter)”."))
        }
        return rows
    }

    private func content(of file: Patch.File, comments: [Comment]) -> [Row] {
        if file.isTooLarge {
            return [.note("Too large to show here: +\(file.added) −\(file.removed)", id: "note:\(file.path)")]
        }
        if file.hunks.isEmpty {
            let note = file.isBinary ? "Binary file" : file.modeChange.map { "Mode changed: \($0)" } ?? "No lines changed"
            return [.note(note, id: "note:\(file.path)")]
        }
        let shown = model.everyHunk.contains(file.path) ? file.hunks.count : min(file.hunks.count, PatchReviewModel.hunksShown)
        var rows: [Row] = []
        for (index, hunk) in file.hunks.prefix(shown).enumerated() {
            rows.append(.hunk(file, index))
            for line in hunk.lines.indices {
                rows.append(.line(file, hunk: index, line: line))
                for (number, comment) in comments.enumerated() where comment.hunk == index && comment.line == line {
                    rows.append(.comment(comment.text, id: "comment:\(file.path):\(index):\(line):\(number)"))
                }
            }
        }
        if shown < file.hunks.count { rows.append(.more(file, file.hunks.count - shown)) }
        return rows
    }

    @ViewBuilder private func view(for row: Row, hint: String?) -> some View {
        switch row {
        case .folder(let folder, let viewed, let total):
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 10.5))
                Text(folder.isEmpty ? "Top level" : folder).font(.system(size: 11, weight: .semibold))
                    .lineLimit(1).truncationMode(.head)
                Text("\(viewed)/\(total)").font(.system(size: 10.5)).monospacedDigit().foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary).padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 3)
        case .file(let file, let comments):
            fileRow(file, comments: comments)
        case .hunk(let file, let index):
            hunkHeader(file.hunks[index])
        case .line(let file, let hunk, let index):
            PatchLineRow(line: file.hunks[hunk].lines[index],
                         isSelected: model.isSelected(path: file.path, hunk: hunk, line: index))
                .onTapGesture {
                    model.select(path: file.path, hunk: hunk, line: index,
                                 extending: NSEvent.modifierFlags.contains(.shift))
                }
                .help(hint ?? "")
        case .comment(let text, _):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "text.bubble.fill").foregroundStyle(.orange)
                Text(text).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 7).padding(.leading, 30).padding(.trailing, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.08))
        case .note(let text, _):
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 34).padding(.vertical, 8)
        case .more(let file, let more):
            Button("Show \(more) more \(more == 1 ? "hunk" : "hunks")") {
                withAnimation(.easeOut(duration: 0.15)) { _ = model.everyHunk.insert(file.path) }
            }
            .buttonStyle(.link).font(.system(size: 11)).padding(.leading, 34).padding(.vertical, 6)
        case .empty(let text):
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).padding(18)
        }
    }

    private func fileRow(_ file: Patch.File, comments: Int) -> some View {
        let viewed = model.viewed.contains(file.path)
        let open = model.expanded.contains(file.path)
        return HStack(spacing: 9) {
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 12)
            Text(file.name).font(.system(size: 12.5, weight: .medium, design: .monospaced))
                .foregroundStyle(viewed ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
            if file.status != .modified {
                badge(file.status.rawValue)
                    .help(file.status == .renamed || file.status == .copied ? "From \(file.oldPath ?? "")" : "")
            }
            if file.isBinary { badge("binary") }
            if let mode = file.modeChange { badge(mode) }
            if comments > 0 {
                Label("\(comments)", systemImage: "text.bubble.fill").font(.system(size: 10.5)).foregroundStyle(.orange)
                    .help(comments == 1 ? "1 comment" : "\(comments) comments")
            }
            Spacer(minLength: 8)
            PatchChangeCounts(added: file.added, removed: file.removed, dimmed: viewed)
            Toggle("Viewed", isOn: Binding(get: { viewed }, set: { isViewed in
                withAnimation(.easeOut(duration: 0.15)) { model.setViewed(file.path, isViewed) }
            }))
            .toggleStyle(.checkbox).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).frame(height: 32)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { model.toggle(file.path) } }
        .background(open ? Color.primary.opacity(0.06) : .clear)
        .opacity(viewed ? 0.62 : 1)
        .help(file.path)
    }

    private func badge(_ text: String) -> some View {
        Text(text).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 1).background(.quaternary, in: Capsule())
    }

    private func hunkHeader(_ hunk: Patch.Hunk) -> some View {
        HStack(spacing: 8) {
            Text(hunk.header).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.blue)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 8)
            // In a series, which commit made the change.
            if model.patch.commits.count > 1, let index = hunk.commit, model.patch.commits.indices.contains(index) {
                let commit = model.patch.commits[index]
                Text([commit.shortSHA, commit.subject].compactMap { $0 }.joined(separator: " "))
                    .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
            }
        }
        .padding(.leading, 18).padding(.trailing, 12).frame(height: 22)
        .background(Color.blue.opacity(0.08))
    }
}

/// One line of a hunk: its numbers before and after, and the code.
private struct PatchLineRow: View {
    let line: Patch.Line
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "").frame(width: 40, alignment: .trailing)
            Text(line.newNumber.map(String.init) ?? "").frame(width: 40, alignment: .trailing)
            Text(marker).foregroundStyle(line.kind == .added ? Color.green : Color.red).frame(width: 20)
            (Text(line.text.replacingOccurrences(of: "\t", with: "    ")).foregroundStyle(line.kind == .removed ? Color.red.opacity(0.9) : Color.primary)
                + Text(line.noNewlineAtEnd ? "  ⊘ no newline at end of file" : "").foregroundStyle(Color.secondary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.tertiary)
        .padding(.vertical, 1.5).padding(.trailing, 12)
        .background(background)
        .overlay(alignment: .leading) {
            if isSelected { Rectangle().fill(Color.accentColor).frame(width: 3) }
        }
        .contentShape(Rectangle())
    }

    private var marker: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        case .context: ""
        }
    }

    private var background: Color {
        if isSelected { return Color.accentColor.opacity(0.28) }
        switch line.kind {
        case .added: return Color.green.opacity(0.12)
        case .removed: return Color.red.opacity(0.12)
        case .context: return .clear
        }
    }
}
