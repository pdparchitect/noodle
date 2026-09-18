import BrowserBridge
import BrowserCore
import SwiftUI

enum BrowserRecordsKind: String, Identifiable { case history = "History", bookmarks = "Bookmarks", downloads = "Downloads"; var id: String { rawValue } }

struct BrowserRecordsView: View {
    let kind: BrowserRecordsKind
    let browserID: UUID
    @ObservedObject var library: BrowserLibrary
    let currentURL: String
    let currentTitle: String
    var embedded = false
    /// Saves and deletes downloads; history and bookmarks need only the library.
    var runtime: BrowserRuntime?
    let open: (String, Bool) -> Void
    @State private var query = ""
    @State private var offset = 0
    @State private var total = 0
    @State private var history: [BrowserHistoryEntry] = []
    @State private var bookmarks: [BrowserBookmark] = []
    @State private var downloads: [BrowserDownloadInfo] = []
    @State private var failure: String?
    @State private var clearing = false
    @State private var deleting: Deletion?
    @State private var draft: BookmarkDraft?
    @FocusState private var searching: Bool
    private let pageSize = 50
    /// A delete waiting for confirmation; nothing is removed until the alert's Delete runs `perform`.
    private struct Deletion { let title: String; let message: String; let perform: () throws -> Void }
    // Downloads live in the profile archive, not the records database, so they are paged here.
    private var downloadRecords: [BrowserDownloadInfo] { (try? library.profile(browserID))?.downloads ?? [] }
    private var empty: (title: String, symbol: String) {
        switch kind {
        case .history: ("No history", "clock")
        case .bookmarks: ("No bookmarks", "book")
        case .downloads: ("No downloads", "arrow.down.circle")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(kind.rawValue).font(embedded ? .title2.weight(.semibold) : .headline)
                Spacer()
                switch kind {
                case .bookmarks:
                    // Prefilled from the current page when it can be bookmarked; a blank tab starts an empty draft.
                    Button("Add") {
                        let page = (try? BrowserRequest.navigationURL(currentURL)) != nil
                        draft = .init(bookmark: nil, title: page ? currentTitle : "", url: page ? currentURL : "")
                    }.help("Add Bookmark")
                case .history:
                    Button("Clear") { clearing = true }.disabled(total == 0 && query.isEmpty)
                case .downloads: EmptyView()
                }
            }.frame(minHeight: 28)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $query).textFieldStyle(.plain).focused($searching)
            }.padding(.horizontal, 12).padding(.vertical, 9)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle()).onTapGesture { searching = true }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    switch kind {
                    case .history:
                        ForEach(history) { entry in
                            row(title: entry.title, subtitle: entry.url, detail: visitDate(entry.visitedAt)) { open(entry.url, true) }
                                .contextMenu {
                                    Button("Open in New Tab") { open(entry.url, true) }
                                    Button("Delete…", role: .destructive) {
                                        deleting = .init(title: "Delete this history entry?", message: entry.url) { try library.removeHistory(browserID, visit: entry.id) }
                                    }
                                }
                        }
                    case .bookmarks:
                        ForEach(bookmarks) { bookmark in
                            row(title: bookmark.title, subtitle: bookmark.url) { open(bookmark.url, true) }
                                .contextMenu {
                                    Button("Open in New Tab") { open(bookmark.url, true) }
                                    Button("Edit…") { draft = .init(bookmark: bookmark, title: bookmark.title, url: bookmark.url) }
                                    Button("Delete…", role: .destructive) {
                                        deleting = .init(title: "Delete “\(bookmark.title)”?", message: bookmark.url) { try library.removeBookmark(browserID, bookmark: bookmark.id) }
                                    }
                                }
                        }
                    case .downloads:
                        ForEach(downloads) { download in
                            row(title: download.filename, subtitle: download.error ?? download.state.capitalized,
                                action: download.state == "complete" ? { save(download) } : nil)
                                .contextMenu {
                                    if download.state == "complete" { Button("Save…") { save(download) } }
                                    Button("Delete…", role: .destructive) {
                                        deleting = .init(title: "Delete “\(download.filename)”?", message: "This also deletes the file stored in this browser.") {
                                            try runtime?.removeDownload(browserID: browserID, downloadID: download.id)
                                        }
                                    }
                                }
                        }
                    }
                }
            }.overlay {
                if total == 0 && failure == nil {
                    ContentUnavailableView(query.isEmpty ? empty.title : "No results", systemImage: empty.symbol)
                }
            }
            HStack {
                Text(total == 0 ? "0 items" : "\(offset + 1)–\(min(offset + pageSize, total)) of \(total)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { offset = max(0, offset - pageSize); refresh() } label: { Image(systemName: "chevron.left") }.disabled(offset == 0).help("Previous Page")
                Button { offset += pageSize; refresh() } label: { Image(systemName: "chevron.right") }.disabled(offset + pageSize >= total).help("Next Page")
            }
        }.padding(embedded ? 24 : 18)
            .frame(width: embedded ? nil : 440, height: embedded ? nil : 460)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(embedded ? Color.clear : Color(nsColor: .windowBackgroundColor))
            .task(id: library.recordsRevision) { refresh() }
            .onChange(of: query) { _, _ in offset = 0; refresh() }
            .onChange(of: downloadRecords) { _, _ in if kind == .downloads { refresh() } }
            .alert("Clear browsing history?", isPresented: $clearing) {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) { do { try library.clearHistory(browserID); offset = 0 } catch { failure = error.localizedDescription } }
            } message: { Text("This clears this browser’s history. Bookmarks and website data are kept.") }
            .alert(deleting?.title ?? "", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), presenting: deleting) { deletion in
                Button("Cancel", role: .cancel) {}
                Button("Delete", role: .destructive) { attempt(deletion.perform) }
            } message: { Text($0.message) }
            .sheet(item: $draft) { draft in BookmarkEditor(browserID: browserID, library: library, draft: draft) }
    }
    /// Clicking a row runs its primary action; everything else lives in its context menu.
    private func row(title: String, subtitle: String, detail: String? = nil, action: (() -> Void)?) -> some View {
        Button { action?() } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 9).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func attempt(_ action: () throws -> Void) {
        do { try action(); failure = nil } catch { failure = error.localizedDescription }
    }
    private func save(_ download: BrowserDownloadInfo) {
        guard let runtime else { return }
        attempt {
            let source = try runtime.downloadURL(browserID: browserID, record: download)
            let panel = NSSavePanel(); panel.nameFieldStringValue = download.filename
            panel.begin { result in
                if result == .OK, let url = panel.url { Task { do { try await runtime.exportUserFile(source, to: url) } catch { failure = error.localizedDescription } } }
            }
        }
    }
    private func refresh() {
        do {
            switch kind {
            case .history: let page = try library.history(browserID, query: query, limit: pageSize, offset: offset); history = page.entries; total = page.total
            case .bookmarks: let page = try library.bookmarks(browserID, query: query, limit: pageSize, offset: offset); bookmarks = page.entries; total = page.total
            case .downloads:
                let matches = downloadRecords.reversed().filter { query.isEmpty || $0.filename.localizedCaseInsensitiveContains(query) }
                downloads = Array(matches.dropFirst(offset).prefix(pageSize)); total = matches.count
            }
            if offset >= total && offset != 0 { offset = max(0, (max(total, 1) - 1) / pageSize * pageSize); refresh(); return }
            failure = nil
        } catch { failure = error.localizedDescription }
    }
    private func visitDate(_ value: String) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)?.formatted(date: .abbreviated, time: .shortened) ?? value
    }
}

struct BookmarkDraft: Identifiable {
    var id = UUID()
    var bookmark: BrowserBookmark?
    var title: String
    var url: String
    var browserID: UUID?
}
struct BookmarkEditor: View {
    let browserID: UUID
    let library: BrowserLibrary
    @State var draft: BookmarkDraft
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(draft.bookmark == nil ? "Add Bookmark" : "Edit Bookmark").font(.headline)
            TextField("Title", text: $draft.title).textFieldStyle(.roundedBorder)
            TextField("URL", text: $draft.url).textFieldStyle(.roundedBorder)
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer(); Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    do {
                        if let bookmark = draft.bookmark { try library.updateBookmark(browserID, bookmark: bookmark.id, url: draft.url, title: draft.title) }
                        else { try library.addBookmark(browserID, url: draft.url, title: draft.title) }
                        dismiss()
                    } catch { failure = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 380)
    }
}
