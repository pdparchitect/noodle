import AppKit
import BrowserBridge
import BrowserCore
import NoodleSettingsUI
import NoodleWallpaper
import SwiftUI
import WebKit

private let browserTabCornerRadius: CGFloat = 7
private let browserTabInset: CGFloat = 8

struct BrowserProfileIcon: View {
    let profile: BrowserProfile
    var size: CGFloat = 42
    var body: some View {
        BrowserIcon(appearance: .init(symbol: profile.symbol, colour: profile.colour, image: profile.iconImage), symbol: "globe", size: size)
    }
}

struct BrowserLibraryView: View {
    @ObservedObject var presentation: BrowserPresentation
    @ObservedObject private var library: BrowserLibrary
    @ObservedObject private var runtime: BrowserRuntime
    @State private var search = ""
    @State private var deleting: BrowserProfile?
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @AppStorage("BrowserSidebarVisible") private var sidebarVisible = true
    @State private var dismissedLibraryFailure = false

    init(presentation: BrowserPresentation) {
        self.presentation = presentation; library = presentation.library; runtime = presentation.runtime
    }
    private var filtered: [BrowserProfile] {
        library.profiles.filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.description?.localizedCaseInsensitiveContains(search) == true
        }
    }
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: $presentation.selection) {
                Section("Browsers") {
                    ForEach(filtered) { profile in
                        BrowserSidebarRow(profile: profile)
                            .tag(profile.id)
                            .contextMenu {
                                Button("Edit Browser…", systemImage: "slider.horizontal.3") { presentation.editing = profile }
                                Button("Change Background…", systemImage: "photo") { presentation.backgroundEditing = profile }
                                Button(profile.paused ? "Resume Agents" : "Pause Agents", systemImage: profile.paused ? "play.fill" : "pause.fill") {
                                    do { try runtime.setPaused(!profile.paused, browserID: profile.id) } catch { runtime.failure = error.localizedDescription }
                                }
                                Divider()
                                Button("Delete Browser…", systemImage: "trash", role: .destructive) { deleting = profile }
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .background(Color.black.opacity(0.24).ignoresSafeArea())
            .searchable(text: $search, placement: .sidebar, prompt: "Search")
            .controlSize(.large)
            .navigationSplitViewColumnWidth(min: 280, ideal: 326, max: 380)
            .overlay {
                if !library.profiles.isEmpty && filtered.isEmpty { ContentUnavailableView.search(text: search) }
            }
            // SwiftUI places its own sidebar toggle last in the sidebar's toolbar
            // section, so while the sidebar is open the column declares the toggle
            // itself to let Create follow it, apart from Back and Forward. Column
            // items are hidden with the sidebar; the system toggle returns then.
            .toolbar(removing: columnVisibility == .detailOnly ? nil : .sidebarToggle)
            .toolbar {
                if columnVisibility != .detailOnly {
                    ToolbarSpacer(.flexible)
                    ToolbarItem {
                        Button { withAnimation { columnVisibility = .detailOnly } } label: { Label("Hide Sidebar", systemImage: "sidebar.leading") }
                            .help("Hide Sidebar")
                    }
                    ToolbarSpacer(.fixed)
                    ToolbarItem {
                        Button { presentation.showingNew = true } label: { Label("Create", systemImage: "plus") }.help("Create Browser")
                    }
                }
            }
        } detail: {
            if let profile = presentation.profile {
                BrowserDetailView(presentation: presentation, profile: profile, sidebarCollapsed: columnVisibility == .detailOnly)
                    .id(profile.id)
            } else {
                ContentUnavailableView {
                    Label("Browsers", systemImage: "globe")
                }
                .toolbar { CompanionSettingsToolbarItem(spacing: .flexible) }
            }
        }
        .navigationSplitViewStyle(.balanced)
        .navigationTitle(presentation.profile?.name ?? BrowserBuildIdentity.current.appName)
        .background {
            ConversationWallpaper(background: presentation.profile?.background ?? .init(),
                imageURL: presentation.profile.flatMap { library.backgroundURL(for: $0) })
                .overlay(alignment: .top) { ConversationWindowHeaderShade() }.ignoresSafeArea()
        }
        .background(ConversationWindowCompositing())
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .onAppear { columnVisibility = sidebarVisible ? .all : .detailOnly }
        .onChange(of: columnVisibility) { _, value in sidebarVisible = value != .detailOnly }
        .onChange(of: library.profiles.map(\.id)) { _, ids in
            if !ids.contains(presentation.selection ?? UUID()) { presentation.selection = ids.first }
        }
        .task(id: presentation.selection) {
            guard let id = presentation.selection else { return }
            do { try runtime.openBrowser(id) } catch { runtime.failure = error.localizedDescription }
        }
        .sheet(isPresented: $presentation.showingNew) { BrowserProfileEditor(presentation: presentation) }
        .sheet(item: $presentation.editing) { BrowserProfileEditor(presentation: presentation, profile: $0) }
        .sheet(item: $presentation.backgroundEditing) { profile in
            BrowserBackgroundSheet(background: profile.background, imageURL: library.backgroundURL(for: profile)) { background, file in
                var current = try library.profile(profile.id)
                current.background = background
                try library.update(current, backgroundFile: file)
            }
        }
        .sheet(item: $presentation.bookmarkDraft) { draft in
            if let id = draft.browserID { BookmarkEditor(browserID: id, library: library, draft: draft) }
        }
        .alert("Delete \(deleting?.name ?? "Browser")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Cancel", role: .cancel) { deleting = nil }
            Button("Delete", role: .destructive) {
                if let id = deleting?.id { Task { do { try await runtime.removeBrowser(id) } catch { runtime.failure = error.localizedDescription } } }
                deleting = nil
            }
        } message: { Text("This deletes its tabs, history, bookmarks, website data and transferred files.") }
        .alert(BrowserBuildIdentity.current.appName, isPresented: Binding(
            get: { runtime.failure != nil || (library.failure != nil && !dismissedLibraryFailure) },
            set: { if !$0 { runtime.failure = nil; dismissedLibraryFailure = true } }
        )) { Button("OK") { runtime.failure = nil; dismissedLibraryFailure = true } }
        message: { Text(runtime.failure ?? library.failure ?? "") }
    }
}

private struct BrowserSidebarRow: View {
    let profile: BrowserProfile
    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .bottomTrailing) {
                BrowserProfileIcon(profile: profile)
                Circle().fill(profile.paused ? Color.orange : Color.green).frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 2))
                    .help(profile.paused ? "Agent control paused" : "Ready")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                Text(profile.paused ? "Agents paused" : (profile.tabs.count == 1 ? "1 tab" : "\(profile.tabs.count) tabs"))
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading).help(profile.description ?? "")
        }.frame(height: 66).contentShape(Rectangle())
            .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
            .listRowSeparator(.visible, edges: .bottom).listRowSeparatorTint(Color.primary.opacity(0.12))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(profile.name), \(profile.tabs.count) tabs, \(profile.paused ? "Agents paused" : "Ready")")
    }
}

private struct BrowserDetailView: View {
    @ObservedObject var presentation: BrowserPresentation
    let profile: BrowserProfile
    let sidebarCollapsed: Bool
    @State private var tabStripWidth: CGFloat = 0
    private var selected: BrowserTab? { presentation.currentTab }

    var body: some View {
        VStack(spacing: 0) {
            switch presentation.mode {
            case .browser:
                tabStrip
                if let selected, selected.info.url != "about:blank" {
                    BrowserTabView(tab: selected)
                } else {
                    BrowserStartPage(profile: profile, presentation: presentation)
                }
            case .history, .bookmarks, .downloads:
                BrowserRecordsView(kind: BrowserRecordsKind(rawValue: presentation.mode.rawValue) ?? .history,
                    browserID: profile.id, library: presentation.library,
                    currentURL: selected?.info.url ?? "", currentTitle: selected?.info.title ?? "", embedded: true,
                    runtime: presentation.runtime) {
                        presentation.navigate($0, newTab: $1)
                    }.id(presentation.mode)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.76))
        .companionContentPanel(sidebarCollapsed: sidebarCollapsed)
        .task(id: profile.selectedTabID) {
            if let id = profile.selectedTabID {
                do { _ = try presentation.runtime.tab(browserID: profile.id, tabID: id) } catch { presentation.runtime.failure = error.localizedDescription }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { selected?.web.goBack() } label: { Label("Back", systemImage: "chevron.left") }.disabled(selected?.web.canGoBack != true).help("Back")
                Button { selected?.web.goForward() } label: { Label("Forward", systemImage: "chevron.right") }.disabled(selected?.web.canGoForward != true).help("Forward")
            }
            ToolbarSpacer(.flexible, placement: .automatic)
            ToolbarItem(id: "browser-address", placement: .automatic) {
                BrowserAddressField(presentation: presentation, url: selected?.info.url ?? "", loading: selected?.info.loading ?? false)
            }
            ToolbarSpacer(.flexible, placement: .automatic)
            ToolbarItem(placement: .primaryAction) {
                Picker("Browser View", selection: $presentation.mode) {
                    ForEach(BrowserDetailMode.allCases) { mode in
                        Image(systemName: mode.symbol).tag(mode).help(mode.rawValue).accessibilityLabel(mode.rawValue)
                    }
                }.pickerStyle(.segmented).labelsHidden().fixedSize().accessibilityValue(presentation.mode.rawValue)
            }
            ToolbarItem(id: "browser-edit", placement: .primaryAction) {
                Button { presentation.editing = profile } label: { Label("Edit Browser", systemImage: "slider.horizontal.3") }.help("Edit Browser")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { do { try await presentation.runtime.setMuted(!profile.muted, browserID: profile.id) } catch { presentation.runtime.failure = error.localizedDescription } }
                } label: { Label(profile.muted ? "Unmute" : "Mute", systemImage: profile.muted ? "speaker.slash" : "speaker.wave.2") }
                    .help(profile.muted ? "Unmute and resume media" : "Mute and pause media")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    do { try presentation.runtime.setPaused(!profile.paused, browserID: profile.id) } catch { presentation.runtime.failure = error.localizedDescription }
                } label: { Label(profile.paused ? "Resume Agents" : "Pause Agents", systemImage: profile.paused ? "play.fill" : "pause.fill") }
                    .help(profile.paused ? "Resume Agents" : "Pause Agents")
            }
            CompanionSettingsToolbarItem()
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(profile.tabs) { tab in
                        ZStack(alignment: .trailing) {
                            Button { presentation.selectTab(tab.id) } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: "globe").font(.caption).foregroundStyle(.secondary)
                                    Text(tab.title).font(.system(size: 12.5)).lineLimit(1)
                                        .frame(minWidth: 60, maxWidth: 170, alignment: .leading)
                                }
                                .padding(.leading, 10).padding(.trailing, 30).frame(height: 32)
                                .contentShape(Rectangle())
                            }
                            .accessibilityIdentifier("browser.tab.\(tab.id)")
                            Button {
                                do { try presentation.runtime.closeTab(browserID: profile.id, tabID: tab.id) } catch { presentation.runtime.failure = error.localizedDescription }
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                                    .frame(width: 24, height: 32).contentShape(Rectangle())
                            }.padding(.trailing, 4).help("Close Tab")
                                .accessibilityIdentifier("browser.tab.close.\(tab.id)")
                        }.buttonStyle(.plain)
                            .background(profile.selectedTabID == tab.id ? Color.primary.opacity(0.10) : Color.clear,
                                in: RoundedRectangle(cornerRadius: browserTabCornerRadius, style: .continuous))
                            .fixedSize()
                    }
                    // Only the space after the last tab opens a tab; the tabs are
                    // siblings, so double-clicking one never reaches this gesture.
                    Color.clear.frame(height: 32).contentShape(Rectangle())
                        .onTapGesture(count: 2) { presentation.newTab() }
                        .accessibilityHidden(true)
                }.frame(minWidth: tabStripWidth, alignment: .leading)
            }.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tabStripWidth = $0 }
            Button { presentation.newTab() } label: { Image(systemName: "plus") }.buttonStyle(.borderless).help("New Tab").padding(.horizontal, 8)
                .accessibilityIdentifier("browser.tab.new")
        }.padding(browserTabInset)
    }
}

private struct BrowserAddressField: View {
    @ObservedObject var presentation: BrowserPresentation
    let url: String
    let loading: Bool
    @State private var address = ""
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: url.hasPrefix("https://") ? "lock" : "magnifyingglass").font(.caption).foregroundStyle(.secondary)
            TextField("Search or enter address", text: $address)
                .textFieldStyle(.plain).focused($focused).onSubmit { presentation.navigate(address); focused = false }
                .accessibilityLabel("Address").accessibilityIdentifier("browser.address")
            Button {
                if loading { presentation.currentTab?.web.stopLoading() } else { presentation.currentTab?.web.reload() }
            } label: { Image(systemName: loading ? "xmark" : "arrow.clockwise").font(.caption) }
                .buttonStyle(.plain).help(loading ? "Stop Loading" : "Reload")
        }.padding(.horizontal, 12).padding(.vertical, 9)
            .frame(minWidth: 120, idealWidth: 360, maxWidth: 560)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
            .onAppear { address = url == "about:blank" ? "" : url }
            .onChange(of: url) { _, value in if !focused { address = value == "about:blank" ? "" : value } }
            .onChange(of: presentation.addressFocusRequest) { _, _ in focused = true }
    }
}

private struct BrowserStartPage: View {
    let profile: BrowserProfile
    @ObservedObject var presentation: BrowserPresentation
    @State private var search = ""
    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            BrowserProfileIcon(profile: profile, size: 72)
            Text(profile.name).font(.system(size: 25, weight: .semibold))
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search or enter address", text: $search).textFieldStyle(.plain).onSubmit { presentation.navigate(search) }
            }.padding(14).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12)).frame(maxWidth: 420)
            if let bookmarks = try? presentation.library.bookmarks(profile.id, limit: 6).entries, !bookmarks.isEmpty {
                HStack(spacing: 18) {
                    ForEach(bookmarks) { bookmark in
                        Button { presentation.navigate(bookmark.url) } label: {
                            VStack(spacing: 8) {
                                Image(systemName: "bookmark").font(.title3).frame(width: 42, height: 42)
                                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                                Text(bookmark.title).font(.caption).lineLimit(1).frame(width: 70)
                            }
                        }.buttonStyle(.plain).help(bookmark.url)
                    }
                }.padding(.top, 8)
            }
            Spacer(); Spacer()
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct BrowserTabView: View {
    @ObservedObject var tab: BrowserTab
    @State private var dialogText = ""
    var body: some View {
        VStack(spacing: 0) {
            if let error = tab.info.error { Text(error).font(.caption).foregroundStyle(.red).padding(8) }
            if let dialog = tab.dialog {
                HStack {
                    VStack(alignment: .leading) { Text(dialog.origin).font(.caption.weight(.semibold)); Text(dialog.message).lineLimit(4) }
                    if dialog.kind == "prompt" { TextField(dialog.defaultText ?? "", text: $dialogText).textFieldStyle(.roundedBorder) }
                    Spacer()
                    if dialog.kind != "alert" { Button("Cancel") { tab.answerDialog(accept: false, text: nil) } }
                    Button("OK") { tab.answerDialog(accept: true, text: dialogText) }
                }.padding(12)
            }
            BrowserWebView(tab: tab).id(tab.id)
        }
    }
}
private struct BrowserWebView: NSViewRepresentable {
    let tab: BrowserTab
    func makeCoordinator() -> BrowserTab { tab }
    func makeNSView(context: Context) -> BrowserWebContainer {
        tab.detachSurface()
        return BrowserWebContainer(web: tab.web)
    }
    func updateNSView(_ view: BrowserWebContainer, context: Context) {}
    static func dismantleNSView(_ view: BrowserWebContainer, coordinator: BrowserTab) {
        coordinator.detachSurface(); coordinator.restoreSurface()
    }
}

private final class BrowserWebContainer: NSView {
    let web: WKWebView
    init(web: WKWebView) {
        self.web = web
        super.init(frame: .zero)
        clipsToBounds = true
        web.autoresizingMask = []
        addSubview(web)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        // SwiftUI briefly gives a newly mounted native view a zero frame. Keep
        // that measurement pass from resizing the live page or moving its scroll.
        guard web.superview === self, bounds.width > 0, bounds.height > 0 else { return }
        if web.frame != bounds { web.frame = bounds }
    }
}
