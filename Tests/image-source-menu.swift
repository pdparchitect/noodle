// Compile with Sources/Noodle/ImageSourceMenu.swift. No Noodle store is opened.
import AppKit
import SwiftUI

private struct Fixture: View {
    let title: String
    let width: CGFloat
    let enabled: Bool
    let chooseFile: () -> Void
    let choosePhoto: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ImageSourceMenu(title: title, chooseFile: chooseFile, choosePhoto: choosePhoto)
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

@main private enum ImageSourceMenuTest {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        var files = 0
        var photos = 0
        for title in ["Choose Image…", "Choose Background…"] {
            for width: CGFloat in [320, 374, 472] {
                for enabled in [true, false] {
                    let view = NSHostingView(rootView: Fixture(title: title, width: width, enabled: enabled,
                        chooseFile: { files += 1 }, choosePhoto: { photos += 1 }))
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 40),
                                          styleMask: [.borderless], backing: .buffered, defer: false)
                    window.contentView = view
                    window.orderFront(nil)
                    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                    view.layoutSubtreeIfNeeded()
                    let button = findView(view) { $0 is ImageMenuAnchorView }!
                    let create = findView(view) { $0.identifier?.rawValue == "create-image-frame" }!
                    let rect = button.convert(button.bounds, to: view)
                    let createRect = create.convert(create.bounds, to: view)
                    precondition(abs(rect.minX) < 0.5, "Chooser has a left inset: \(rect)")
                    precondition(abs(rect.width - (width - 8) / 2) < 0.5, "Chooser must fill exactly half the row: \(rect)")
                    precondition(abs(rect.width - createRect.width) < 0.5, "Button widths differ")
                    precondition(abs(rect.height - createRect.height) < 0.5, "Button heights differ: \(rect) / \(createRect)")
                    precondition(abs(rect.minY - createRect.minY) < 0.5, "Button tops differ")
                    if enabled {
                        let presenter = ImageSourceMenu.Presenter()
                        let menu = presenter.makeMenu(chooseFile: { files += 1 }, choosePhoto: { photos += 1 })
                        precondition(menu.items.map(\.title) == ["Choose File…", "Photos Library…"])
                        for item in menu.items {
                            precondition(NSApp.sendAction(item.action!, to: item.target, from: item))
                        }
                    }
                    window.orderOut(nil)
                }
            }
        }
        precondition(files == 6 && photos == 6, "File and Photos actions must route independently")
        print("Image source menu: equal button widths, heights and tops for both titles at three widths in enabled/disabled layouts; both menu actions passed")
    }

    @MainActor private static func findView(_ view: NSView, matching predicate: (NSView) -> Bool) -> NSView? {
        if predicate(view) { return view }
        for child in view.subviews {
            if let match = findView(child, matching: predicate) { return match }
        }
        return nil
    }
}
