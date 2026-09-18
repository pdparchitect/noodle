import BrowserBridge
import BrowserCore
import SwiftUI

enum BrowserRecordsKind: String, Identifiable { case history = "History", bookmarks = "Bookmarks"; var id: String { rawValue } }

struct BrowserRecordsView: View {
    let kind: BrowserRecordsKind
    let browserID: UUID
    @ObservedObject var library: BrowserLibrary
    let currentURL: String
    let currentTitle: String
    var embedded = false
    let open: (String, Bool) -> Void
    @State private var query = ""
    @State private var offset = 0
    @State private var total = 0
    @State private var history: [BrowserHistoryEntry] = []
    @State private var bookmarks: [BrowserBookmark] = []
    @State private var failure: String?
    @State private var clearing = false
    @State private var draft: BookmarkDraft?
    @FocusState private var searching: Bool
    private let pageSize = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(kind.rawValue).font(embedded ? .title2.weight(.semibold) : .headline)
                Spacer()
                if kind == .bookmarks {
                    Button("Add") { draft = .init(bookmark: nil, title: currentTitle, url: currentURL) }
                        .help("Add Bookmark").disabled((try? BrowserRequest.navigationURL(currentURL)) == nil)
                } else {
                    Button("Clear") { clearing = true }.disabled(total == 0 && query.isEmpty)
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
                    if kind == .history {
                        ForEach(history) { entry in
                            row(title: entry.title, url: entry.url, detail: visitDate(entry.visitedAt))
                                .contextMenu { Button("Open in New Tab") { open(entry.url, true) } }
                        }
                    } else {
                        ForEach(bookmarks) { bookmark in
                            row(title: bookmark.title, url: bookmark.url)
                                .contextMenu {
                                    Button("Open in New Tab") { open(bookmark.url, true) }
                                    Button("Edit…") { draft = .init(bookmark: bookmark, title: bookmark.title, url: bookmark.url) }
                                    Button("Delete", role: .destructive) {
                                        do { try library.removeBookmark(browserID, bookmark: bookmark.id) } catch { failure = error.localizedDescription }
                                    }
                                }
                        }
                    }
                }
            }.overlay {
                if total == 0 && failure == nil {
                    ContentUnavailableView(query.isEmpty ? (kind == .history ? "No history" : "No bookmarks") : "No results", systemImage: kind == .history ? "clock" : "book")
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
            .alert("Clear browsing history?", isPresented: $clearing) {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) { do { try library.clearHistory(browserID); offset = 0 } catch { failure = error.localizedDescription } }
            } message: { Text("This clears this browser’s history. Bookmarks and website data are kept.") }
            .sheet(item: $draft) { draft in BookmarkEditor(browserID: browserID, library: library, draft: draft) }
    }
    private func row(title: String, url: String, detail: String? = nil) -> some View {
        Button { open(url, true) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                Text(url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let detail { Text(detail).font(.caption2).foregroundStyle(.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 9).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    private func refresh() {
        do {
            if kind == .history { let page = try library.history(browserID, query: query, limit: pageSize, offset: offset); history = page.entries; total = page.total }
            else { let page = try library.bookmarks(browserID, query: query, limit: pageSize, offset: offset); bookmarks = page.entries; total = page.total }
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
