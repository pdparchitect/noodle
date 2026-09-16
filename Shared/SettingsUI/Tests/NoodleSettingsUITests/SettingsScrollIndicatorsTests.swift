import AppKit
import SwiftUI
import XCTest
import NoodleSettingsUI

@MainActor final class SettingsScrollIndicatorsTests: XCTestCase {
    func testTabChangesAndRepeatedResizesRestoreIndicatorsWithoutDisablingScrolling() async throws {
        let fixture = try await fixture()
        fixture.selection.tab = 1
        try await wait { fixture.probe.visibility == .hidden }
        for height: CGFloat in [310, 330, 350] {
            fixture.window.setContentSize(.init(width: 580, height: height))
            XCTAssertEqual(fixture.window.contentRect(forFrameRect: fixture.window.frame).height, height, accuracy: 0.5)
            try await Task.sleep(for: .milliseconds(180))
            XCTAssertEqual(fixture.probe.visibility, .hidden)
            XCTAssertTrue(fixture.probe.scrollingEnabled)
        }
        let scroll = try XCTUnwrap(find(fixture.host, type: NSScrollView.self))
        scroll.contentView.scroll(to: .init(x: 0, y: 80))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 0)
        try await wait { fixture.probe.visibility == .automatic }
    }

    func testLiveResizeStaysSuppressedDuringPausesAndIgnoresOtherWindows() async throws {
        let fixture = try await fixture()
        let other = window()
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: other)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(fixture.probe.visibility, .automatic)

        NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: fixture.window)
        try await wait { fixture.probe.visibility == .hidden }
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(fixture.probe.visibility, .hidden)
        NotificationCenter.default.post(name: NSWindow.didResizeNotification, object: fixture.window)
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(fixture.probe.visibility, .hidden)
        NotificationCenter.default.post(name: NSWindow.didEndLiveResizeNotification, object: fixture.window)
        try await wait { fixture.probe.visibility == .automatic }
    }

    func testMovingContentDetachesTheOldWindowObserver() async throws {
        let fixture = try await fixture()
        let replacement = window()
        fixture.window.contentView = nil
        replacement.contentView = fixture.host
        try await wait { fixture.probe.visibility == .hidden }
        try await wait { fixture.probe.visibility == .automatic }
        NotificationCenter.default.post(name: NSWindow.willStartLiveResizeNotification, object: fixture.window)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(fixture.probe.visibility, .automatic)
        replacement.setContentSize(.init(width: 580, height: 360))
        try await wait { fixture.probe.visibility == .hidden }
        try await wait { fixture.probe.visibility == .automatic }
    }

    private func fixture() async throws -> (window: NSWindow, host: NSView, selection: Selection, probe: IndicatorView) {
        guard #available(macOS 27.0, *) else { throw XCTSkip("Workaround is specific to macOS 27") }
        let selection = Selection()
        let host = NSHostingView(rootView: SettingsFixture(selection: selection))
        host.sizingOptions = []
        let window = window()
        window.contentView = host
        // Exercise the hosting-window lifecycle offscreen without taking focus.
        window.orderBack(nil)
        var probe: IndicatorView?
        try await wait {
            host.layoutSubtreeIfNeeded()
            probe = self.find(host, type: IndicatorView.self)
            return probe != nil
        }
        let result = try XCTUnwrap(probe)
        try await wait { result.visibility == .automatic }
        return (window, host, selection, result)
    }

    private func window() -> NSWindow {
        _ = NSApplication.shared
        let window = FixtureWindow(contentRect: .init(x: -10000, y: -10000, width: 580, height: 300),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { @MainActor in window.contentView = nil; window.close() }
        return window
    }

    private func wait(file: StaticString = #filePath, line: UInt = #line, _ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() {
            for window in NSApp.windows {
                window.contentView?.needsLayout = true
                window.contentView?.layoutSubtreeIfNeeded()
            }
            guard ContinuousClock.now < deadline else {
                XCTFail("Settings indicators did not settle", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func find<V: NSView>(_ root: NSView, type: V.Type) -> V? {
        if let result = root as? V { return result }
        for child in root.subviews {
            if let result = find(child, type: type) { return result }
        }
        return nil
    }
}

@MainActor private final class Selection: ObservableObject {
    @Published var tab = 0
}

private struct SettingsFixture: View {
    @ObservedObject var selection: Selection

    var body: some View {
        VStack {
            Text("Tab \(selection.tab)")
            ScrollView {
                VStack { ForEach(0..<60) { Text("Setting \($0)") } }
            }
            .background(IndicatorProbe())
        }
        .settingsScrollIndicators(selection: selection.tab)
    }
}

private struct IndicatorProbe: NSViewRepresentable {
    @Environment(\.verticalScrollIndicatorVisibility) private var visibility
    @Environment(\.isScrollEnabled) private var scrollingEnabled

    func makeNSView(context: Context) -> IndicatorView { IndicatorView() }
    func updateNSView(_ view: IndicatorView, context: Context) {
        view.visibility = visibility
        view.scrollingEnabled = scrollingEnabled
    }
}

private final class IndicatorView: NSView {
    var visibility: ScrollIndicatorVisibility = .automatic
    var scrollingEnabled = true
}

private final class FixtureWindow: NSWindow {
    // Keep the fixture offscreen, including on test runners without a display.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
