import HubLink
import NoodlePatch
import SwiftUI

extension LinkAttachment {
    /// A `.patch` or `.diff` file. It opens in a review when it reads as a patch, and in Quick Look when it does not.
    var isPatchFile: Bool {
        voice == nil && url == nil && Patch.isPatchFile(name: filename, mediaType: mediaType)
    }
}

/// A patch to review, opened from its card.
struct PatchReviewRequest: Identifiable {
    let attachment: LinkAttachment
    let patch: Patch
    /// The patch on this phone, to share.
    let file: URL
    var id: UUID { attachment.id }
}

extension EnvironmentValues {
    /// Opens a patch's review, presented by the conversation rather than the card, which the
    /// conversation unloads as it scrolls. Without it a patch opens in Quick Look.
    @Entry var reviewPatch: (@MainActor (PatchReviewRequest) -> Void)?
}

// MARK: - Card

/// A patch in a conversation: its commits and who made them, the files that changed most, and its totals.
struct PatchCard: View {
    let patch: Patch
    let filename: String
    static let shown = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch").font(.caption2.weight(.semibold))
                    Text(patch.headline(filename: filename)).font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if patch.commits.count > 1 {
                        Text("\(patch.commits.count) commits").font(.caption2.weight(.bold)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 1).background(Color.accentColor, in: Capsule())
                    }
                }
                .foregroundStyle(.secondary).padding(.bottom, 2)
                ForEach(patch.largestFiles(Self.shown)) { file in
                    HStack(spacing: 6) {
                        Text(file.name).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        PatchCounts(added: file.added, removed: file.removed)
                    }
                }
                if patch.fileCount > Self.shown {
                    Text("+ \(patch.fileCount - Self.shown) more").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(Color(.tertiarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.branch").font(.title3).foregroundStyle(.secondary).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(filename).font(.subheadline.weight(.medium)).lineLimit(2)
                    Text(patch.totals).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .frame(width: 280)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens its review")
    }
}

/// "+148 −49", in green and red.
struct PatchCounts: View {
    let added: Int
    let removed: Int
    var dimmed = false

    var body: some View {
        HStack(spacing: 4) {
            Text("+\(added)").foregroundStyle(dimmed ? AnyShapeStyle(HierarchicalShapeStyle.secondary) : AnyShapeStyle(Color.green))
            if removed > 0 {
                Text("−\(removed)").foregroundStyle(dimmed ? AnyShapeStyle(HierarchicalShapeStyle.secondary) : AnyShapeStyle(Color.red))
            }
        }
        .font(.caption.monospaced()).monospacedDigit()
    }
}

// MARK: - Review

/// Where someone is in a review: what they ticked off and what they are looking for.
@MainActor @Observable final class PatchReviewModel {
    struct Folder: Identifiable {
        var path: String
        /// The files shown, filtered.
        var files: [Patch.File]
        var viewed: Int
        var total: Int
        var id: String { path }
    }

    let patch: Patch
    private(set) var viewed: Set<String>
    var filter = ""
    var hidesViewed = false
    var showsWalkthrough = true
    private let save: (Set<String>) -> Void

    init(patch: Patch, viewed: Set<String>, save: @escaping (Set<String>) -> Void) {
        self.patch = patch; self.viewed = viewed; self.save = save
    }

    func isViewed(_ file: Patch.File) -> Bool { viewed.contains(file.path) }

    func setViewed(_ path: String, _ isViewed: Bool) {
        if isViewed { viewed.insert(path) } else { viewed.remove(path) }
        save(viewed)
    }

    var viewedCount: Int { patch.files.count { viewed.contains($0.path) } }

    /// Files by folder, in order, as the filter and Hide Viewed leave them.
    var folders: [Folder] {
        let shown = patch.files.filter { file in
            (filter.isEmpty || file.path.localizedCaseInsensitiveContains(filter)) && !(hidesViewed && viewed.contains(file.path))
        }
        let every = Dictionary(grouping: patch.files, by: \.folder)
        return Dictionary(grouping: shown, by: \.folder)
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { folder, files in
                let all = every[folder] ?? []
                return Folder(path: folder, files: files, viewed: all.count { viewed.contains($0.path) }, total: all.count)
            }
    }
}

/// A patch: what it changes, the walkthrough of its commits, and every file to tick off and open.
/// Only to read: comments on a patch are made on the Mac.
struct PatchReviewScreen: View {
    let request: PatchReviewRequest
    @State private var model: PatchReviewModel
    @Environment(\.dismiss) private var dismiss

    init(request: PatchReviewRequest, viewed: Set<String>, save: @escaping (Set<String>) -> Void) {
        self.request = request
        _model = State(initialValue: PatchReviewModel(patch: request.patch, viewed: viewed, save: save))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(model.patch.summary).font(.subheadline).foregroundStyle(.secondary)
                    progress
                }
                if !model.patch.commits.isEmpty { walkthrough }
                let folders = model.folders
                ForEach(folders) { folder in
                    Section {
                        ForEach(folder.files) { file in
                            NavigationLink(value: file.path) { PatchFileRow(file: file, model: model) }
                                .swipeActions(edge: .leading) { viewedAction(file) }
                                .swipeActions(edge: .trailing) { viewedAction(file) }
                        }
                    } header: {
                        HStack(spacing: 6) {
                            Image(systemName: "folder")
                            Text(folder.path.isEmpty ? "Top Level" : folder.path).lineLimit(1).truncationMode(.head)
                            Spacer()
                            Text("\(folder.viewed)/\(folder.total)").monospacedDigit()
                        }
                        .textCase(nil)
                    }
                }
                if folders.isEmpty {
                    Text(model.filter.isEmpty ? "Every file is viewed." : "No file matches “\(model.filter)”.")
                        .foregroundStyle(.secondary)
                }
            }
            .searchable(text: $model.filter, prompt: "Filter Files")
            .navigationTitle(model.patch.title(filename: request.attachment.filename))
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { path in
                if let file = model.patch.files.first(where: { $0.path == path }) {
                    PatchFileScreen(file: file, model: model)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        withAnimation { model.hidesViewed.toggle() }
                    } label: {
                        Label(model.hidesViewed ? "Show Viewed" : "Hide Viewed",
                              systemImage: model.hidesViewed ? "eye.slash" : "eye")
                    }
                    ShareLink(item: request.file)
                }
            }
        }
    }

    private var progress: some View {
        let total = model.patch.files.count, viewed = model.viewedCount
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(viewed) of \(total) viewed").font(.subheadline.weight(.semibold)).monospacedDigit()
            ProgressView(value: Double(viewed), total: Double(max(total, 1)))
        }
        .padding(.vertical, 2)
    }

    private var walkthrough: some View {
        let commits = model.patch.commits
        return Section {
            if model.showsWalkthrough {
                ForEach(Array(commits.enumerated()), id: \.offset) { index, commit in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1)").font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(commit.subject).font(.subheadline.weight(.medium))
                            if let sha = commit.shortSHA {
                                Text(sha).font(.caption.monospaced()).foregroundStyle(.tertiary)
                            }
                            if let note = commit.flowingNote {
                                Text(note).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Button {
                withAnimation { model.showsWalkthrough.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("Walkthrough · \(commits.count) \(commits.count == 1 ? "step" : "steps")")
                    Spacer()
                    Image(systemName: "chevron.right").rotationEffect(.degrees(model.showsWalkthrough ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .textCase(nil)
            .accessibilityValue(model.showsWalkthrough ? "Shown" : "Hidden")
        }
    }

    private func viewedAction(_ file: Patch.File) -> some View {
        let viewed = model.isViewed(file)
        return Button(viewed ? "Not Viewed" : "Viewed", systemImage: viewed ? "circle" : "checkmark.circle") {
            withAnimation { model.setViewed(file.path, !viewed) }
        }
        .tint(viewed ? .gray : .green)
    }
}

/// A file in the review, with its Viewed tick.
private struct PatchFileRow: View {
    let file: Patch.File
    let model: PatchReviewModel

    var body: some View {
        let viewed = model.isViewed(file)
        HStack(spacing: 10) {
            Button {
                withAnimation { model.setViewed(file.path, !viewed) }
            } label: {
                Image(systemName: viewed ? "checkmark.circle.fill" : "circle").font(.title3)
                    .foregroundStyle(viewed ? AnyShapeStyle(Color.green) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Viewed")
            .accessibilityValue(viewed ? "Yes" : "No")
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name).font(.subheadline.monospaced().weight(.medium)).lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(viewed ? .secondary : .primary)
                PatchFileBadges(file: file)
            }
            Spacer(minLength: 6)
            PatchCounts(added: file.added, removed: file.removed, dimmed: viewed)
        }
        .opacity(viewed ? 0.7 : 1)
    }
}

/// Added, deleted, renamed, binary or a mode change: what the lines alone do not say.
private struct PatchFileBadges: View {
    let file: Patch.File

    var body: some View {
        let badges = [file.status == .modified ? nil : file.status.rawValue, file.isBinary ? "binary" : nil, file.modeChange]
            .compactMap { $0 }
        if !badges.isEmpty {
            HStack(spacing: 4) {
                ForEach(badges, id: \.self) { badge in
                    Text(badge).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1).background(.quaternary, in: Capsule())
                }
            }
        }
    }
}

/// One file's changes: its hunks with line numbers before and after, lines wrapped to the screen.
struct PatchFileScreen: View {
    let file: Patch.File
    let model: PatchReviewModel
    @Environment(\.dismiss) private var dismiss

    private enum Row: Identifiable {
        case hunk(Int)
        case line(hunk: Int, line: Int)

        var id: String {
            switch self {
            case .hunk(let hunk): "hunk:\(hunk)"
            case .line(let hunk, let line): "line:\(hunk):\(line)"
            }
        }
    }

    var body: some View {
        let viewed = model.isViewed(file)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                header.padding(.horizontal, 16).padding(.vertical, 12)
                if let note {
                    Text(note).font(.subheadline).foregroundStyle(.secondary).padding(16)
                }
                let width = numberWidth
                ForEach(rows) { row in
                    switch row {
                    case .hunk(let index): hunkHeader(file.hunks[index])
                    case .line(let hunk, let line): PatchLineRow(line: file.hunks[hunk].lines[line], numberWidth: width)
                    }
                }
                if !viewed {
                    Button {
                        model.setViewed(file.path, true)
                        dismiss()
                    } label: {
                        Label("Mark as Viewed", systemImage: "checkmark.circle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered).controlSize(.large).padding(16)
                }
            }
        }
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.setViewed(file.path, !viewed)
                } label: {
                    Label("Viewed", systemImage: viewed ? "checkmark.circle.fill" : "circle")
                }
                .tint(viewed ? Color.green : nil)
                .accessibilityValue(viewed ? "Yes" : "No")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(file.path).font(.footnote.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            if file.status == .renamed || file.status == .copied, let old = file.oldPath {
                Text("From \(old)").font(.caption.monospaced()).foregroundStyle(.tertiary)
            }
            HStack(spacing: 8) {
                PatchCounts(added: file.added, removed: file.removed)
                PatchFileBadges(file: file)
            }
        }
    }

    private var note: String? {
        if file.isTooLarge { return "Too large to show here: +\(file.added) −\(file.removed)" }
        guard file.hunks.isEmpty else { return nil }
        return file.isBinary ? "Binary file" : file.modeChange.map { "Mode changed: \($0)" } ?? "No lines changed"
    }

    private var rows: [Row] {
        file.hunks.indices.flatMap { hunk in [Row.hunk(hunk)] + file.hunks[hunk].lines.indices.map { Row.line(hunk: hunk, line: $0) } }
    }

    /// Room for the longest line number of the file.
    private var numberWidth: CGFloat {
        let largest = file.hunks.map { max($0.oldStart + $0.oldCount, $0.newStart + $0.newCount) }.max() ?? 0
        return CGFloat(String(largest).count) * 6.5 + 6
    }

    private func hunkHeader(_ hunk: Patch.Hunk) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(hunk.header).font(.caption.monospaced()).foregroundStyle(Color.blue).lineLimit(1).truncationMode(.tail)
            // In a series, which commit made the change.
            if model.patch.commits.count > 1, let index = hunk.commit, model.patch.commits.indices.contains(index) {
                let commit = model.patch.commits[index]
                Text([commit.shortSHA, commit.subject].compactMap { $0 }.joined(separator: " "))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.blue.opacity(0.1))
    }
}

/// One line of a hunk: its numbers before and after, and the code, wrapped.
private struct PatchLineRow: View {
    let line: Patch.Line
    let numberWidth: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "").frame(width: numberWidth, alignment: .trailing)
            Text(line.newNumber.map(String.init) ?? "").frame(width: numberWidth, alignment: .trailing)
            Text(marker).foregroundStyle(line.kind == .added ? Color.green : Color.red).frame(width: 16)
            Text("\(code)\(Text(line.noNewlineAtEnd ? "  ⊘ no newline at end of file" : "").foregroundStyle(Color.secondary))")
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.tertiary)
        .padding(.vertical, 1.5).padding(.trailing, 8)
        .background(background)
        .accessibilityElement(children: .combine)
    }

    private var code: Text {
        Text(line.text.replacingOccurrences(of: "\t", with: "    "))
            .foregroundStyle(line.kind == .removed ? Color.red.opacity(0.9) : Color.primary)
    }

    private var marker: String {
        switch line.kind {
        case .added: "+"
        case .removed: "−"
        case .context: ""
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: Color.green.opacity(0.14)
        case .removed: Color.red.opacity(0.14)
        case .context: .clear
        }
    }
}
