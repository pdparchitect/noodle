import AppKit
import BrowserBridge
import BrowserCore
import SwiftUI

/// A browser's tab strip drawn where nobody clicks it directly, for a live view: the picture,
/// and which of its targets a point falls on.
@MainActor final class BrowserTabStripPicture {
    private let panel: NSPanel
    private let host: NSHostingView<AnyView>
    private var targets: [BrowserTabStripTarget: CGRect] = [:]

    init() {
        host = NSHostingView(rootView: AnyView(EmptyView()))
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 800, height: BrowserTabStrip.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.contentView = host
    }

    /// The strip at `width` points, `scale` pixels to a point.
    func render(tabs: [BrowserTabInfo], selected: UUID?, width: CGFloat, scale: CGFloat) -> CGImage? {
        host.rootView = AnyView(BrowserTabStrip(tabs: tabs, selectedTabID: selected, select: { _ in }, close: { _ in }, newTab: {},
                                                layout: { [weak self] in self?.targets = $0 })
            .frame(width: width, height: BrowserTabStrip.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        panel.setContentSize(CGSize(width: width, height: BrowserTabStrip.height))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let drawn = rep.cgImage else { return nil }
        let pixels = (width: Int((width * scale).rounded()), height: Int((BrowserTabStrip.height * scale).rounded()))
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

/// A browser as someone watching it live sees it: its tab strip above the selected tab, as in
/// its window but without the address bar. Clicks on the strip select, close and open tabs, as
/// the window's do; everything else reaches the page.
@MainActor final class BrowserLiveView {
    private let browserID: UUID
    private weak var runtime: BrowserRuntime?
    private let strip = BrowserTabStripPicture()
    /// Whether the button went down on the strip, so its drag and release go there too.
    private var pressedOnStrip: Bool?

    init(browserID: UUID, runtime: BrowserRuntime) {
        self.browserID = browserID
        self.runtime = runtime
    }

    func picture() async throws -> (image: CGImage, size: CGSize) {
        let profile = try profile()
        let page = try await selectedTab(profile).surfacePicture()
        let scale = CGFloat(page.image.width) / max(1, page.size.width)
        let stripHeight = Int((BrowserTabStrip.height * scale).rounded())
        guard let tabs = strip.render(tabs: profile.tabs, selected: profile.selectedTabID, width: page.size.width, scale: scale),
              let context = CGContext(data: nil, width: page.image.width, height: page.image.height + stripHeight, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { throw BrowserError("The browser cannot be shown.") }
        context.draw(page.image, in: CGRect(x: 0, y: 0, width: page.image.width, height: page.image.height))
        context.draw(tabs, in: CGRect(x: 0, y: page.image.height, width: page.image.width, height: stripHeight))
        guard let image = context.makeImage() else { throw BrowserError("The browser cannot be shown.") }
        return (image, CGSize(width: page.size.width, height: page.size.height + BrowserTabStrip.height))
    }

    func apply(_ input: SurfaceInput) throws {
        let top = BrowserTabStrip.height
        switch input {
        case .pointer(let phase, let x, let y, let count):
            if phase == .down { pressedOnStrip = y < top }
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
            try selectedTab(profile()).apply(input)
        }
    }

    private func act(on target: BrowserTabStripTarget) throws {
        guard let runtime else { return }
        switch target {
        case .tab(let id): try runtime.selectTab(browserID: browserID, tabID: id)
        case .close(let id): try runtime.closeTab(browserID: browserID, tabID: id)
        case .newTab: _ = try runtime.makeTab(browserID: browserID)
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
