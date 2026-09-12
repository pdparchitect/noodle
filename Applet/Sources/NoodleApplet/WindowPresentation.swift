import AppKit
import AppletCore

@MainActor enum WindowPresentation {
  static func make(_ options: NoodletWindowOptions, size: CGSize) -> NSWindow {
    let frame = CGRect(origin: .zero, size: size)
    if options.type == .preview {
      let panel = NSPanel(contentRect: frame, styleMask: [.titled, .closable, .resizable, .utilityWindow, .hudWindow, .nonactivatingPanel], backing: .buffered, defer: false)
      panel.isReleasedWhenClosed = false
      panel.hidesOnDeactivate = false
      panel.isFloatingPanel = true
      panel.becomesKeyOnlyIfNeeded = false
      return panel
    }
    let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
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
    if !options.titlebar || options.type == .preview {
      window.titleVisibility = .hidden
      window.titlebarAppearsTransparent = true
      window.styleMask.insert(.fullSizeContentView)
      window.isMovableByWindowBackground = true
    }
    if options.background != .opaque {
      window.isOpaque = false
      window.backgroundColor = .clear
    }
    if options.background == .translucent {
      let effect = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
      effect.material = .hudWindow
      effect.blendingMode = .behindWindow
      effect.state = .active
      content.frame = effect.bounds
      content.autoresizingMask = [.width, .height]
      effect.addSubview(content)
      window.contentView = effect
    } else {
      window.contentView = content
    }
    if !options.titlebar || options.type == .preview, let container = window.contentView {
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

@MainActor private final class NoodletTitlebarDragView: NSView {
  override var mouseDownCanMoveWindow: Bool { true }
  override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}
