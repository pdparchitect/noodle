import AppKit
import SwiftUI
import XCTest
@testable import NoodleWallpaper

@MainActor final class IconEditorSheetTests: XCTestCase {
    private let companionSymbols = ["desktopcomputer", "terminal", "shippingbox", "server.rack", "laptopcomputer", "globe",
        "sparkles", "bolt.fill", "brain.head.profile", "hammer.fill", "paintbrush.fill", "gearshape.2.fill"]
    private let botSymbols = ["sparkles", "bolt.fill", "brain.head.profile", "hammer.fill", "terminal.fill", "magnifyingglass",
        "shippingbox.fill", "paintbrush.fill", "checkmark.seal.fill", "ladybug.fill", "wand.and.stars", "gearshape.2.fill"]

    /// The same bound Noodle Computer's smoke test places on its icon editor.
    func testKeepsTheCompactLayoutForEveryAppsConfiguration() async throws {
        let configurations: [(String, IconAppearance, String, [String], IconImageEncoding)] = [
            ("Browser Icon", IconAppearance(symbol: "globe", colour: 2), "globe", companionSymbols, .png(maxBytes: 2 * 1024 * 1024)),
            ("Computer Icon", IconAppearance(colour: 4), "terminal", companionSymbols, .png(maxBytes: 2 * 1024 * 1024)),
            // A bot's colour is a seed until the user picks one: 1_000_003 % 6 == 1.
            ("Bot Icon", IconAppearance(colour: 1_000_003), "sparkles", botSymbols, .jpeg(quality: 0.86))
        ]
        for (title, icon, symbol, symbols, encoding) in configurations {
            let host = NSHostingView(rootView: IconEditorSheet(title: title, icon: .constant(icon), symbol: symbol,
                symbols: symbols, encoding: encoding).background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 570),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderBack(nil)
            defer { window.orderOut(nil) }
            try await Task.sleep(for: .milliseconds(300))
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(host.bounds.width, 440, accuracy: 1, title)
            XCTAssertLessThan(host.bounds.height, 610, title)
            if let folder = ProcessInfo.processInfo.environment["NOODLE_ICON_EDITOR_SNAPSHOTS"] {
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(title).png"))
            }
        }
    }
}
