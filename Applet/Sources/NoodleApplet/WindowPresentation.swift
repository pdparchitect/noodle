import AppKit
import WebKit
import AppletBridge
import AppletCore

/// Where the window of a noodlet the user is watching sits, so its next version takes its place.
struct WindowPlace: Codable, Equatable {
  var frame: CGRect
  /// Whether the user was working in the noodlet, the only time its next version takes the keyboard.
  var focused: Bool
  var window: Int
}

@MainActor enum WindowPresentation {
  /// Straight over the window it replaces, so nothing jumps or flashes.
  static func present(_ window: NSWindow, in place: WindowPlace) {
    window.setFrame(place.frame, display: true)
    if place.focused {
      window.makeKeyAndOrderFront(nil)
      NSApp.activate(ignoringOtherApps: true)
    } else {
      window.order(.above, relativeTo: place.window)
    }
  }
  static func make(_ options: NoodletWindowOptions, size: CGSize) -> NSWindow {
    let frame = CGRect(origin: .zero, size: size)
    if options.type == .preview {
      let panel = PagePanel(contentRect: frame, styleMask: [.titled, .closable, .resizable, .utilityWindow, .hudWindow, .nonactivatingPanel], backing: .buffered, defer: false)
      panel.isReleasedWhenClosed = false
      panel.hidesOnDeactivate = false
      panel.isFloatingPanel = true
      panel.becomesKeyOnlyIfNeeded = false
      return panel
    }
    let window =
      options.cornerRadius == nil
      ? PageWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
      : UntitledWindow(contentRect: frame, styleMask: [.closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    return window
  }
  static func apply(
    _ options: NoodletWindowOptions, to window: NSWindow, content: NSView,
    size: CGSize, key: String, remember: Bool
  ) {
    if !options.resizable { window.styleMask.remove(.resizable) }
    window.level = options.type != .standard ? .floating : .normal
    if options.type != .standard { window.collectionBehavior.insert(.fullScreenAuxiliary) }
    // Titled windows get this from AppKit.
    if options.cornerRadius != nil && options.type == .standard { window.collectionBehavior.insert(.fullScreenPrimary) }
    let ownTitlebar = options.titlebar == .none
    if options.titlebar != .visible || options.type == .preview {
      window.titleVisibility = .hidden
      window.titlebarAppearsTransparent = true
      window.styleMask.insert(.fullSizeContentView)
      window.isMovableByWindowBackground = true
    }
    // Hidden, not removed, so the window keeps its actions and their shortcuts.
    if ownTitlebar {
      for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
        window.standardWindowButton(button)?.isHidden = true
      }
    }
    if options.background != .opaque {
      window.isOpaque = false
      window.backgroundColor = .clear
    }
    var root = content
    if options.background == .translucent {
      let effect = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
      effect.material = .hudWindow
      effect.blendingMode = .behindWindow
      effect.state = .active
      content.frame = effect.bounds
      content.autoresizingMask = [.width, .height]
      effect.addSubview(content)
      root = effect
    }
    if let radius = options.cornerRadius, radius > 0 {
      window.isOpaque = false
      window.backgroundColor = .clear
      root = WindowShapeView(root, radius: radius, filled: options.background == .opaque)
    }
    window.contentView = root
    // A page drawing its own title bar handles dragging through CSS regions. A native
    // strip above WebKit would swallow its controls before no-drag can be checked.
    if !ownTitlebar && (options.titlebar != .visible || options.type == .preview), let container = window.contentView {
      let drag = NoodletTitlebarDragView()
      drag.translatesAutoresizingMaskIntoConstraints = false
      container.addSubview(drag, positioned: .above, relativeTo: nil)
      NSLayoutConstraint.activate([
        drag.topAnchor.constraint(equalTo: container.topAnchor),
        drag.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: options.type == .preview ? 28 : 78),
        drag.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        drag.heightAnchor.constraint(equalToConstant: 30)
      ])
    }
    window.contentMinSize = CGSize(
      width: CGFloat(options.minWidth ?? 120), height: CGFloat(options.minHeight ?? 120))
    window.contentMaxSize = CGSize(
      width: CGFloat(options.maxWidth ?? 4096), height: CGFloat(options.maxHeight ?? 4096))
    window.setContentSize(size)
    window.center()
    if remember && options.rememberFrame {
      let name = "Noodlet.\(key)"
      window.setFrameUsingName(name)
      window.setFrameAutosaveName(name)
      // A manifest update can tighten limits after a frame was saved.
      let current = window.contentRect(forFrameRect: window.frame).size
      window.setContentSize(options.size(width: Int(current.width), height: Int(current.height)))
    }
  }
}

extension WindowPresentation {
  /// What a noodlet's own window buttons do. False while the window is out of sight.
  static func perform(_ action: String, on window: NSWindow) throws -> Bool {
    guard ["close", "minimize", "zoom", "toggleFullScreen"].contains(action) else {
      throw AppletError("Unknown window action.")
    }
    guard window.isVisible else { return false }
    switch action {
    case "close": window.performClose(nil)
    case "minimize": window.miniaturize(nil)
    case "zoom": window.zoom(nil)
    default: window.toggleFullScreen(nil)
    }
    return true
  }
}

/// WebKit passes a key the page did not cancel back up to the window, where AppKit beeps, so a game
/// reading the arrow keys without preventDefault beeped on every press. Escape comes back as a
/// cancel command instead, which AppKit beeps at too. The page had the key either way.
@MainActor private func pageHasKeys(in window: NSWindow) -> Bool {
  var view = window.firstResponder as? NSView
  while let current = view, !(current is WKWebView) { view = current.superview }
  return view != nil
}

@MainActor private class PageWindow: NSWindow {
  override func noResponder(for eventSelector: Selector) {
    if eventSelector != #selector(NSResponder.keyDown(with:)) || !pageHasKeys(in: self) { super.noResponder(for: eventSelector) }
  }
  override func doCommand(by selector: Selector) {
    if !pageHasKeys(in: self) { super.doCommand(by: selector) }
  }
}

@MainActor private final class PagePanel: NSPanel {
  override func noResponder(for eventSelector: Selector) {
    if eventSelector != #selector(NSResponder.keyDown(with:)) || !pageHasKeys(in: self) { super.noResponder(for: eventSelector) }
  }
  override func doCommand(by selector: Selector) {
    if !pageHasKeys(in: self) { super.doCommand(by: selector) }
  }
}

/// A noodlet window with a cornerRadius: no title bar, yet it takes the keyboard and closes with ⌘W.
@MainActor private final class UntitledWindow: PageWindow {
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }
  // The inherited one refuses without a close button.
  override func performClose(_ sender: Any?) {
    if delegate?.windowShouldClose?(self) != false { close() }
  }
}

/// Clips a noodlet window to its cornerRadius, over the window background when opaque.
/// Full screen is square, like the screen.
@MainActor private final class WindowShapeView: NSView {
  private let radius: CGFloat
  private let filled: Bool
  init(_ content: NSView, radius: CGFloat, filled: Bool) {
    self.radius = radius
    self.filled = filled
    super.init(frame: content.frame)
    wantsLayer = true
    layer?.masksToBounds = true
    layer?.cornerCurve = .continuous
    content.frame = bounds
    content.autoresizingMask = [.width, .height]
    addSubview(content)
    shape()
  }
  required init?(coder: NSCoder) { nil }
  override var wantsUpdateLayer: Bool { true }
  override func updateLayer() { layer?.backgroundColor = filled ? NSColor.windowBackgroundColor.cgColor : nil }
  override func layout() {
    super.layout()
    shape()
  }
  private func shape() {
    let radius = window?.styleMask.contains(.fullScreen) == true ? 0 : radius
    // Material behind the window is shaped only by its mask.
    if let effect = subviews.first as? NSVisualEffectView {
      effect.maskImage = radius > 0 ? Self.mask(radius) : nil
    } else {
      layer?.cornerRadius = radius
    }
    window?.invalidateShadow()
  }
  private static func mask(_ radius: CGFloat) -> NSImage {
    let side = radius * 2 + 1
    let image = NSImage(size: CGSize(width: side, height: side), flipped: false) { rect in
      NSColor.black.setFill()
      NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
      return true
    }
    image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
    image.resizingMode = .stretch
    return image
  }
}

@MainActor private final class NoodletTitlebarDragView: NSView {
  override var mouseDownCanMoveWindow: Bool { true }
  override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}
