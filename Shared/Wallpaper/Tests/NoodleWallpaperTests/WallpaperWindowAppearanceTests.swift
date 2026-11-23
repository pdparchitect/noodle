import AppKit
import SwiftUI
import XCTest
@testable import NoodleWallpaper

/// A window showing a background is dark, whatever the system's appearance, and stays dark until no
/// wallpaper in it shows one.
@MainActor final class WallpaperWindowAppearanceTests: XCTestCase {
    private static let shader = ConversationBackground(imageFilename: "\(UUID().uuidString.lowercased()).metal", mediaKind: .shader)
    private static let video = ConversationBackground(imageFilename: "\(UUID().uuidString.lowercased()).mp4", mediaKind: .video)
    private static let image = ConversationBackground(imageFilename: "\(UUID().uuidString.lowercased()).jpg", mediaKind: .image)

    private var systemAppearance: NSAppearance?

    override func setUp() async throws {
        // The system in light appearance, where a wallpaper has to turn its window dark itself.
        systemAppearance = NSApplication.shared.appearance
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
    }

    override func tearDown() async throws {
        NSApplication.shared.appearance = systemAppearance
    }

    func testEachKindOfBackgroundTurnsTheWindowDarkAndRemovingItTurnsItBack() async throws {
        let state = WallpaperState(ConversationBackground())
        let window = makeWindow()
        defer { window.close() }
        window.contentView = NSHostingView(rootView: WallpaperFixture(state: state))
        await settle()
        XCTAssertFalse(isDark(window))

        for background in [Self.shader, Self.video, Self.image, ConversationBackground(preset: .midnight)] {
            state.background = background
            await settle()
            XCTAssertTrue(isDark(window), "\(background.mediaKind?.rawValue ?? "preset") background")
        }
        state.background = ConversationBackground()
        await settle()
        XCTAssertFalse(isDark(window))
    }

    /// Replacing a shader with another one, or an image with a shader and back, keeps the window dark.
    func testReplacingOneBackgroundWithAnotherKeepsTheWindowDark() async throws {
        let state = WallpaperState(Self.shader)
        let window = makeWindow()
        defer { window.close() }
        window.contentView = NSHostingView(rootView: WallpaperFixture(state: state))
        await settle()
        XCTAssertTrue(isDark(window))
        for background in [ConversationBackground(imageFilename: "\(UUID().uuidString.lowercased()).metal", mediaKind: .shader),
                           Self.image, Self.shader, Self.video] {
            state.background = background
            await settle()
            XCTAssertTrue(isDark(window), "after \(background.imageFilename ?? "")")
        }
    }

    /// Columns each draw their own wallpaper in one window beside the window's own, empty one:
    /// whichever updates last must not turn the window light while a column shows a background.
    func testAWallpaperWithoutABackgroundDoesNotTurnLightAWindowAnotherOneMadeDark() async throws {
        let window = makeWindow()
        defer { window.close() }
        let container = NSView(frame: window.contentLayoutRect)
        window.contentView = container
        let column = NSHostingView(rootView: WallpaperFixture(state: WallpaperState(Self.shader)))
        column.frame = container.bounds
        container.addSubview(column)
        await settle()
        XCTAssertTrue(isDark(window))

        let plain = WallpaperState(ConversationBackground())
        let windowWallpaper = NSHostingView(rootView: WallpaperFixture(state: plain))
        windowWallpaper.frame = container.bounds
        container.addSubview(windowWallpaper, positioned: .below, relativeTo: column)
        await settle()
        XCTAssertTrue(isDark(window), "a wallpaper without a background turned the window light")

        column.removeFromSuperview()
        await settle()
        XCTAssertFalse(isDark(window), "the last background is gone")
    }

    /// Something else resetting the window's appearance, as a change of the system's appearance or a
    /// closing sheet may, does not leave a window that shows a background light.
    func testWindowTurnsDarkAgainWhenItsAppearanceIsReset() async throws {
        let window = makeWindow()
        defer { window.close() }
        window.contentView = NSHostingView(rootView: WallpaperFixture(state: WallpaperState(Self.shader)))
        await settle()
        XCTAssertTrue(isDark(window))

        window.appearance = nil
        await settle()
        XCTAssertTrue(isDark(window), "the window stayed light after its appearance was reset")

        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        await settle()
        NSApplication.shared.appearance = NSAppearance(named: .aqua)
        await settle()
        XCTAssertTrue(isDark(window), "the window turned light with the system")
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: .init(x: 80, y: 80, width: 480, height: 360),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return window
    }

    private func isDark(_ window: NSWindow) -> Bool {
        window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private func settle() async {
        for _ in 0..<5 {
            await Task.yield()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }
}

@MainActor private final class WallpaperState: ObservableObject {
    @Published var background: ConversationBackground
    init(_ background: ConversationBackground) { self.background = background }
}

private struct WallpaperFixture: View {
    @ObservedObject var state: WallpaperState
    var body: some View {
        ConversationWallpaper(background: state.background).frame(width: 480, height: 360)
    }
}
