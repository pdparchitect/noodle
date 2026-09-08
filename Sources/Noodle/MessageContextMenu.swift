import AppKit
import ImageIO
import SwiftUI
import NoodleCore

/// Only handles right clicks; text selection and attachment clicks pass through unchanged.
struct MessageContextMenu: NSViewRepresentable {
    let selected: Set<String>
    let react: (String) -> Void
    let copy: () -> Void
    let preview: (() -> Void)?
    let reveal: (() -> Void)?
    var backgroundImageURL: URL? = nil
    var useAsBackground: (() -> Void)? = nil

    func makeNSView(context: Context) -> MenuHost { MenuHost() }

    func updateNSView(_ nsView: MenuHost, context: Context) {
        nsView.configuration = self
    }

    final class MenuHost: NSView {
        var configuration: MessageContextMenu?
        private var actions: [() -> Void] = []
        private var emojiInput: EmojiInputView?

        override func hitTest(_ point: NSPoint) -> NSView? {
            guard NSApp.currentEvent?.type == .rightMouseDown else { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) {
            guard let configuration else { return }
            let menu = NSMenu()
            menu.autoenablesItems = false
            actions = []
            for emojis in [["❤️", "👍", "👎", "😂", "🎉", "❓"], ["👀", "⏳", "✅", "🙏", "🔥", "💡"]] {
                let item = NSMenuItem()
                item.view = EmojiRow(emojis: emojis, selected: configuration.selected) { [weak menu] emoji in
                    menu?.cancelTracking()
                    configuration.react(emoji)
                }
                menu.addItem(item)
            }
            addItem("More Emoji…", symbol: "face.smiling", to: menu) { [weak self] in
                // End menu tracking before opening the system's single emoji picker.
                DispatchQueue.main.async { self?.showEmojiPicker() }
            }
            menu.addItem(.separator())
            addItem("Copy", symbol: "doc.on.doc", to: menu, action: configuration.copy)
            if let preview = configuration.preview {
                addItem("Quick Look", symbol: "eye", to: menu, action: preview)
            }
            if let reveal = configuration.reveal {
                addItem("Show in Finder", symbol: "folder", to: menu, action: reveal)
            }
            // Inspect only when opening the menu, not while scrolling the transcript.
            // Decode detection also covers real images with generic attachment MIME types.
            if let url = configuration.backgroundImageURL,
               let useAsBackground = configuration.useAsBackground,
               CGImageSourceCreateWithURL(url as CFURL, nil) != nil {
                menu.addItem(.separator())
                addItem("Use as Conversation Background", symbol: "photo", to: menu, action: useAsBackground)
            }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            actions = []
        }

        private func showEmojiPicker() {
            guard let window, let configuration else { return }
            emojiInput?.removeFromSuperview()
            let input = EmojiInputView(frame: NSRect(x: bounds.midX, y: bounds.midY, width: 1, height: 1))
            input.previousResponder = window.firstResponder
            input.drawsBackground = false
            input.textColor = .clear
            input.insertionPointColor = .clear
            input.choose = configuration.react
            addSubview(input)
            emojiInput = input
            window.makeFirstResponder(input)
            NSApp.orderFrontCharacterPalette(nil)
        }

        private func addItem(_ title: String, symbol: String, to menu: NSMenu, action: @escaping () -> Void) {
            let item = NSMenuItem(title: title, action: #selector(invokeItem(_:)), keyEquivalent: "")
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            item.target = self
            item.tag = actions.count
            actions.append(action)
            menu.addItem(item)
        }

        @objc private func invokeItem(_ sender: NSMenuItem) {
            guard actions.indices.contains(sender.tag) else { return }
            actions[sender.tag]()
        }
    }

    final class EmojiInputView: NSTextView {
        weak var previousResponder: NSResponder?
        var choose: ((String) -> Void)?

        override func insertText(_ insertString: Any, replacementRange: NSRange) {
            let value = (insertString as? NSAttributedString)?.string ?? (insertString as? String) ?? ""
            guard MessageReaction.isValidEmoji(value) else { return }
            let callback = choose
            finish()
            callback?(value)
        }

        override func cancelOperation(_ sender: Any?) { finish() }

        private func finish() {
            choose = nil
            if window?.firstResponder === self { window?.makeFirstResponder(previousResponder) }
            removeFromSuperview()
        }
    }

    private final class EmojiRow: NSView {
        private let emojis: [String]
        private let choose: (String) -> Void

        init(emojis: [String], selected: Set<String>, choose: @escaping (String) -> Void) {
            self.emojis = emojis
            self.choose = choose
            super.init(frame: NSRect(x: 0, y: 0, width: 258, height: 42))
            for (index, emoji) in emojis.enumerated() {
                let button = HoverEmojiButton(title: emoji, target: self, action: #selector(react(_:)))
                button.frame = NSRect(x: 9 + index * 40, y: 3, width: 38, height: 36)
                button.font = .systemFont(ofSize: 22)
                button.isBordered = false
                button.tag = index
                button.setAccessibilityLabel("React \(emoji)")
                button.toolTip = selected.contains(emoji) ? "Remove your \(emoji) reaction" : "React \(emoji)"
                if selected.contains(emoji) {
                    button.wantsLayer = true
                    button.layer?.cornerRadius = 8
                    button.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.25).cgColor
                }
                addSubview(button)
            }
        }

        required init?(coder: NSCoder) { nil }

        @objc private func react(_ sender: NSButton) {
            choose(emojis[sender.tag])
        }
    }

    private final class HoverEmojiButton: NSButton {
        private var hoverTrackingArea: NSTrackingArea?
        private let emojiLayer = CATextLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            emojiLayer.alignmentMode = .center
            layer?.addSublayer(emojiLayer)
        }

        required init?(coder: NSCoder) { nil }

        override func layout() {
            super.layout()
            // Keep the hit area and layout fixed; only the rendered glyph scales.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            emojiLayer.contentsScale = window?.backingScaleFactor ?? 2
            emojiLayer.string = NSAttributedString(string: title, attributes: [.font: font ?? .systemFont(ofSize: 22)])
            emojiLayer.bounds = CGRect(x: 0, y: 0, width: bounds.width, height: 30)
            emojiLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            CATransaction.commit()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            needsLayout = true
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
            let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            hoverTrackingArea = area
        }

        override func mouseEntered(with event: NSEvent) { animateScale(to: 1.12) }
        override func mouseExited(with event: NSEvent) { animateScale(to: 1) }

        private func animateScale(to value: CGFloat) {
            let current = emojiLayer.presentation()?.transform ?? emojiLayer.transform
            let target = CATransform3DMakeScale(value, value, 1)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            emojiLayer.transform = target
            CATransaction.commit()

            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
                emojiLayer.removeAnimation(forKey: "hover")
                return
            }
            let animation = CABasicAnimation(keyPath: "transform")
            // Reverse from the visible scale, not the previous target, on rapid pointer movement.
            animation.fromValue = NSValue(caTransform3D: current)
            animation.toValue = NSValue(caTransform3D: target)
            animation.duration = 0.18
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            emojiLayer.add(animation, forKey: "hover")
        }

        override func draw(_ dirtyRect: NSRect) {
            // The cached text layer draws the emoji, without per-frame AppKit redraws.
        }
    }
}
