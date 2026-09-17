import AppKit
import BrowserBridge
import BrowserCore
import SwiftUI

enum BrowserDetailMode: String, CaseIterable, Identifiable {
    case browser = "Browser", history = "History", bookmarks = "Bookmarks", downloads = "Downloads"
    var id: Self { self }
    var symbol: String {
        switch self { case .browser: "globe"; case .history: "clock"; case .bookmarks: "book"; case .downloads: "arrow.down.circle" }
    }
}

@MainActor final class BrowserPresentation: ObservableObject {
    let library: BrowserLibrary
    let runtime: BrowserRuntime
    private let defaults: UserDefaults?
    @Published var selection: UUID? {
        didSet {
            defaults?.set(selection?.uuidString, forKey: "SelectedBrowser")
            mode = .browser
        }
    }
    @Published var mode = BrowserDetailMode.browser
    @Published var showingNew = false
    @Published var editing: BrowserProfile?
    @Published var backgroundEditing: BrowserProfile?
    @Published var bookmarkDraft: BookmarkDraft?
    @Published var addressFocusRequest = 0

    init(library: BrowserLibrary, runtime: BrowserRuntime, defaults: UserDefaults? = .standard) {
        self.library = library; self.runtime = runtime; self.defaults = defaults
        let restore = defaults?.object(forKey: "BrowserRestoreSelection") as? Bool ?? true
        let saved = restore ? defaults?.string(forKey: "SelectedBrowser").flatMap(UUID.init(uuidString:)) : nil
        selection = library.profiles.first(where: { $0.id == saved })?.id ?? library.profiles.first?.id
    }
    var profile: BrowserProfile? { library.profiles.first { $0.id == selection } }
    var currentTab: BrowserTab? { profile?.selectedTabID.flatMap { runtime.tabs[$0] } }
    func focusAddress() { mode = .browser; addressFocusRequest &+= 1 }
    func newTab() {
        guard let selection else { return }
        do { _ = try runtime.makeTab(browserID: selection); focusAddress() }
        catch { runtime.failure = error.localizedDescription }
    }
    func selectTab(_ id: UUID) {
        guard let selection else { return }
        do {
            var profile = try library.profile(selection)
            guard profile.tabs.contains(where: { $0.id == id }) else { throw BrowserError("Tab not found in this browser.") }
            profile.selectedTabID = id; try library.update(profile)
            _ = try runtime.tab(browserID: selection, tabID: id); mode = .browser
        } catch { runtime.failure = error.localizedDescription }
    }
    func navigate(_ value: String, newTab: Bool = false) {
        guard let selection else { return }
        do {
            let url = try Self.addressURL(value, searchEngine: defaults?.string(forKey: "BrowserSearchEngine") ?? "duckduckgo")
            let tab = try newTab ? runtime.makeTab(browserID: selection) : (currentTab ?? runtime.makeTab(browserID: selection))
            selectTab(tab.id); tab.navigate(url)
        } catch { runtime.failure = error.localizedDescription }
    }
    static func addressURL(_ value: String, searchEngine: String) throws -> URL {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw BrowserError("Enter an address or search.") }
        if value.contains("://") { return try BrowserRequest.navigationURL(value) }
        if !value.contains(" ") && (value.contains(".") || value.hasPrefix("localhost")) {
            return try BrowserRequest.navigationURL("https://" + value)
        }
        let base: String
        switch searchEngine { case "google": base = "https://www.google.com/search"; case "bing": base = "https://www.bing.com/search"; default: base = "https://duckduckgo.com/" }
        var parts = URLComponents(string: base)!; parts.queryItems = [.init(name: "q", value: value)]
        return parts.url!
    }
    func bookmarkCurrentPage() {
        guard let tab = currentTab, (try? BrowserRequest.navigationURL(tab.info.url)) != nil else { return }
        bookmarkDraft = .init(bookmark: nil, title: tab.info.title, url: tab.info.url, browserID: tab.browserID)
    }
}
