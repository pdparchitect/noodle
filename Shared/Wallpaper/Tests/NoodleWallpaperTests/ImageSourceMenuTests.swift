import AppKit
import SwiftUI
import XCTest
@testable import NoodleWallpaper

private struct Fixture: View {
    let title: String
    let width: CGFloat
    let enabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            ImageSourceMenu(title: title, chooseFile: {}, choosePhoto: {})
                .frame(minWidth: 0, maxWidth: .infinity)
            Button {} label: {
                Label("Create Image…", systemImage: "apple.intelligence")
                    .frame(maxWidth: .infinity)
                    .frame(height: 20)
            }
            .buttonStyle(.bordered)
            .background(FrameProbe())
            .frame(minWidth: 0, maxWidth: .infinity)
        }
        .disabled(!enabled)
        .frame(width: width)
    }
}

private struct FrameProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier("create-image-frame")
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

@MainActor final class ImageSourceMenuTests: XCTestCase {
    func testChooserMatchesCreateImageButtonInEveryLayout() throws {
        for title in ["Choose Image…", "Choose Background…"] {
            for width: CGFloat in [320, 374, 472] {
                for enabled in [true, false] {
                    let view = NSHostingView(rootView: Fixture(title: title, width: width, enabled: enabled))
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 40),
                                          styleMask: [.borderless], backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    window.contentView = view
                    window.orderFront(nil)
                    defer { window.orderOut(nil) }
                    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                    view.layoutSubtreeIfNeeded()
                    let button = try XCTUnwrap(findView(view) { $0 is ImageMenuAnchorView })
                    let create = try XCTUnwrap(findView(view) { $0.identifier?.rawValue == "create-image-frame" })
                    let rect = button.convert(button.bounds, to: view)
                    let createRect = create.convert(create.bounds, to: view)
                    let layout = "\(title) at \(width), enabled \(enabled): \(rect) / \(createRect)"
                    XCTAssertEqual(rect.minX, 0, accuracy: 0.5, "Chooser has a left inset. \(layout)")
                    XCTAssertEqual(rect.width, (width - 8) / 2, accuracy: 0.5, "Chooser must fill exactly half the row. \(layout)")
                    XCTAssertEqual(rect.width, createRect.width, accuracy: 0.5, "Button widths differ. \(layout)")
                    XCTAssertEqual(rect.height, createRect.height, accuracy: 0.5, "Button heights differ. \(layout)")
                    XCTAssertEqual(rect.minY, createRect.minY, accuracy: 0.5, "Button tops differ. \(layout)")
                }
            }
        }
    }

    func testFileAndPhotosActionsRouteIndependently() throws {
        var files = 0, photos = 0
        let presenter = ImageSourceMenu.Presenter()
        let menu = presenter.makeMenu(chooseFile: { files += 1 }, choosePhoto: { photos += 1 })
        XCTAssertEqual(menu.items.map(\.title), ["Choose File…", "Photos Library…"])
        try send(menu.items[0])
        XCTAssertEqual([files, photos], [1, 0])
        try send(menu.items[1])
        XCTAssertEqual([files, photos], [1, 1])
    }

    func testSystemWallpapersItemAppearsOnlyWhenSuppliedAndOpensItsDialog() throws {
        var files = 0, photos = 0, wallpapers = 0
        let presenter = ImageSourceMenu.Presenter()
        let menu = presenter.makeMenu(chooseFile: { files += 1 }, choosePhoto: { photos += 1 },
            chooseWallpaper: { wallpapers += 1 })
        XCTAssertEqual(menu.items.map(\.title), ["Choose File…", "Photos Library…", "System Wallpapers…"])
        XCTAssertNil(menu.items[2].submenu, "Wallpapers open a dialog, not a submenu")
        try send(menu.items[2])
        XCTAssertEqual([files, photos, wallpapers], [0, 0, 1])
    }

    private func send(_ item: NSMenuItem) throws {
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
    }

    private func findView(_ view: NSView, matching predicate: (NSView) -> Bool) -> NSView? {
        if predicate(view) { return view }
        for child in view.subviews {
            if let match = findView(child, matching: predicate) { return match }
        }
        return nil
    }
}
