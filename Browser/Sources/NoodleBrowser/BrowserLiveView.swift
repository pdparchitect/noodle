import AppKit
import BrowserBridge
import BrowserCore
import SwiftUI

/// What a live view shows above the page: the browser's tabs, and below them the back, forward
/// and reload buttons and the address, which its window keeps in the toolbar instead.
struct BrowserLiveChrome: View {
    static let height = BrowserTabStrip.height + 36

    let tabs: [BrowserTabInfo]
    let selectedTabID: UUID?
    let address: String
    let editing: Bool
    let layout: ([BrowserTabStripTarget: CGRect]) -> Void
    @State private var tabTargets: [BrowserTabStripTarget: CGRect] = [:]
    @State private var navigation: [BrowserTabStripTarget: CGRect] = [:]

    var body: some View {
        VStack(spacing: 0) {
            BrowserTabStrip(tabs: tabs, selectedTabID: selectedTabID, select: { _ in }, close: { _ in }, newTab: {},
                            layout: { tabTargets = $0; layout($0.merging(navigation) { $1 }) })
            HStack(spacing: 4) {
                ForEach([(BrowserTabStripTarget.back, "chevron.left"), (.forward, "chevron.right"), (.reload, "arrow.clockwise")],
                        id: \.0) { target, symbol in
                    Image(systemName: symbol).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                        .frame(width: 28, height: 26).located(target, in: $navigation)
                }
                HStack(spacing: 0) {
                    Text(address.isEmpty && !editing ? "Search or enter address" : address)
                        .font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(address.isEmpty ? .secondary : .primary)
                    if editing { Rectangle().fill(Color.accentColor).frame(width: 1.5, height: 15).padding(.leading, 1) }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).frame(height: 26)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(editing ? Color.accentColor : .clear, lineWidth: 1.5))
                .located(.address, in: $navigation)
            }.padding(.horizontal, 8).frame(height: 36)
        }
        .coordinateSpace(.named(BrowserTabStripSpace.name))
        .onChange(of: navigation) { layout(tabTargets.merging(navigation) { $1 }) }
    }
}

/// What is typed into a live view's address bar. The first key replaces the address, as
/// selecting it first would; Return goes to what is there and Escape leaves it.
struct BrowserAddressDraft: Equatable {
    enum Outcome: Equatable { case go(String), cancel }

    private(set) var text: String
    private var untouched = true

    init(address: String) { text = address == "about:blank" ? "" : address }

    mutating func take(_ input: SurfaceInput) -> Outcome? {
        switch input {
        case .text(let typed):
            text = untouched ? typed : text + typed
        case .key(.space):
            text = untouched ? " " : text + " "
        case .key(.backspace):
            text = untouched ? "" : String(text.dropLast())
        case .key(.enter):
            return .go(text)
        case .key(.escape):
            return .cancel
        default:
            return nil
        }
        untouched = false
        return nil
    }
}

/// A live view's chrome drawn where nobody clicks it directly: the picture, and which of its
/// targets a point falls on.
@MainActor final class BrowserTabStripPicture {
    private let panel: NSPanel
    private let host: NSHostingView<AnyView>
    private var targets: [BrowserTabStripTarget: CGRect] = [:]

    init() {
        host = NSHostingView(rootView: AnyView(EmptyView()))
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 800, height: BrowserLiveChrome.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = host
    }

    /// The chrome at `width` points, `scale` pixels to a point.
    func render(tabs: [BrowserTabInfo], selected: UUID?, address: String, editing: Bool, width: CGFloat, scale: CGFloat) -> CGImage? {
        host.rootView = AnyView(BrowserLiveChrome(tabs: tabs, selectedTabID: selected, address: address, editing: editing,
                                                  layout: { [weak self] in self?.targets = $0 })
            .frame(width: width, height: BrowserLiveChrome.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        panel.setContentSize(CGSize(width: width, height: BrowserLiveChrome.height))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let drawn = rep.cgImage else { return nil }
        let pixels = (width: Int((width * scale).rounded()), height: Int((BrowserLiveChrome.height * scale).rounded()))
        guard let context = CGContext(data: nil, width: pixels.width, height: pixels.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(drawn, in: CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height))
        return context.makeImage()
    }

    /// What is under `point`, in the strip's points from its top-left; a close button wins over its tab.
    func target(at point: CGPoint) -> BrowserTabStripTarget? {
        let hits = targets.filter { $0.value.contains(point) }.map(\.key)
        return hits.first { if case .close = $0 { true } else { false } } ?? hits.first
    }
}

/// A browser as someone watching it live sees it: its tabs, navigation and address above the
/// selected tab. Clicks there select, close and open tabs, go back, forward and reload, and
/// start typing an address, as the window's do; everything else reaches the page.
@MainActor final class BrowserLiveView {
    private let browserID: UUID
    private weak var runtime: BrowserRuntime?
    private let strip = BrowserTabStripPicture()
    /// Whether the button went down on the chrome, so its drag and release go there too.
    private var pressedOnStrip: Bool?
    /// What is being typed into the address bar, while it has the keyboard.
    private var draft: BrowserAddressDraft?

    init(browserID: UUID, runtime: BrowserRuntime) {
        self.browserID = browserID
        self.runtime = runtime
    }

    func picture() async throws -> (image: CGImage, size: CGSize) {
        let profile = try profile()
        let page = try await selectedTab(profile).surfacePicture()
        let scale = CGFloat(page.image.width) / max(1, page.size.width)
        let stripHeight = Int((BrowserLiveChrome.height * scale).rounded())
        let address = draft?.text ?? profile.tabs.first { $0.id == profile.selectedTabID }.map { $0.url == "about:blank" ? "" : $0.url } ?? ""
        guard let tabs = strip.render(tabs: profile.tabs, selected: profile.selectedTabID, address: address, editing: draft != nil,
                                      width: page.size.width, scale: scale),
              let context = CGContext(data: nil, width: page.image.width, height: page.image.height + stripHeight, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw BrowserError("The browser cannot be shown.") }
        context.draw(page.image, in: CGRect(x: 0, y: 0, width: page.image.width, height: page.image.height))
        context.draw(tabs, in: CGRect(x: 0, y: page.image.height, width: page.image.width, height: stripHeight))
        guard let image = context.makeImage() else { throw BrowserError("The browser cannot be shown.") }
        return (image, CGSize(width: page.size.width, height: page.size.height + BrowserLiveChrome.height))
    }

    func apply(_ input: SurfaceInput) throws {
        let top = BrowserLiveChrome.height
        switch input {
        case .pointer(let phase, let x, let y, let count):
            if phase == .down { pressedOnStrip = y < top; draft = nil }
            let onStrip = pressedOnStrip ?? (y < top)
            if phase == .up { pressedOnStrip = nil }
            if onStrip {
                if phase == .up, let target = strip.target(at: CGPoint(x: x, y: y)) { try act(on: target) }
                return
            }
            try selectedTab(profile()).apply(.pointer(phase, x: x, y: y - top, clickCount: count))
        case .scroll(let x, let y, let dx, let dy):
            guard y >= top else { return }
            try selectedTab(profile()).apply(.scroll(x: x, y: y - top, dx: dx, dy: dy))
        case .key, .text:
            guard var typing = draft else { return try selectedTab(profile()).apply(input) }
            switch typing.take(input) {
            case .go(let value)?:
                draft = nil
                let url = try BrowserPresentation.addressURL(value, searchEngine: UserDefaults.standard.string(forKey: "BrowserSearchEngine") ?? "duckduckgo")
                try selectedTab(profile()).navigate(url)
            case .cancel?:
                draft = nil
            case nil:
                draft = typing
            }
        }
    }

    private func act(on target: BrowserTabStripTarget) throws {
        guard let runtime else { return }
        switch target {
        case .tab(let id): try runtime.selectTab(browserID: browserID, tabID: id)
        case .close(let id): try runtime.closeTab(browserID: browserID, tabID: id)
        case .newTab:
            _ = try runtime.makeTab(browserID: browserID)
            draft = BrowserAddressDraft(address: "")
        case .back: try selectedTab(profile()).web.goBack()
        case .forward: try selectedTab(profile()).web.goForward()
        case .reload:
            let tab = try selectedTab(profile())
            if tab.info.loading { tab.web.stopLoading() } else { tab.web.reload() }
        case .address:
            let profile = try profile()
            draft = BrowserAddressDraft(address: profile.tabs.first { $0.id == profile.selectedTabID }?.url ?? "")
        }
    }

    private func profile() throws -> BrowserProfile {
        guard let runtime else { throw BrowserError("Browser stopped.") }
        return try runtime.library.profile(browserID)
    }

    private func selectedTab(_ profile: BrowserProfile) throws -> BrowserTab {
        guard let runtime, let id = profile.selectedTabID ?? profile.tabs.first?.id else { throw BrowserError("This browser has no tabs.") }
        return try runtime.tab(browserID: browserID, tabID: id)
    }
}
