import AppKit
import SwiftUI

extension View {
  func noodleSheetSizing(animated: Bool = false) -> some View {
    fixedSize(horizontal: false, vertical: true)
      .background {
        GeometryReader { geometry in
          SheetContentSizeBridge(contentSize: geometry.size, animated: animated)
        }
      }
      .presentationSizing(.fitted)
  }
}

// macOS can retain a sheet's initial window size even after SwiftUI's ideal
// content size changes. Keep the actual sheet in sync, without recreating the
// editor (which would lose drafts, focus and nested presentation state).
private struct SheetContentSizeBridge: NSViewRepresentable {
  let contentSize: CGSize
  let animated: Bool

  func makeNSView(context: Context) -> SheetSizeView { SheetSizeView() }

  func updateNSView(_ view: SheetSizeView, context: Context) {
    view.contentSize = contentSize
    view.animated = animated
    view.scheduleResize()
  }

  final class SheetSizeView: NSView {
    var contentSize = CGSize.zero
    var animated = false
    private var resizeScheduled = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      scheduleResize()
    }

    func scheduleResize() {
      guard !resizeScheduled else { return }
      resizeScheduled = true
      // Resize outside SwiftUI's layout pass and coalesce intermediate
      // measurements from the same update.
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.resizeScheduled = false
        guard let window = self.window, window.sheetParent != nil,
          self.contentSize.width.isFinite, self.contentSize.height.isFinite,
          self.contentSize.width > 0, self.contentSize.height > 0
        else { return }
        let size = NSSize(
          width: ceil(self.contentSize.width), height: ceil(self.contentSize.height))
        let current = window.contentRect(forFrameRect: window.frame).size
        guard abs(current.width - size.width) > 0.5 || abs(current.height - size.height) > 0.5
        else { return }
        if self.animated, window.isVisible,
          !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        {
          var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
          // Keep the sheet attached at its top edge while its body changes.
          frame.origin = NSPoint(
            x: window.frame.midX - frame.width / 2, y: window.frame.maxY - frame.height)
          window.setFrame(frame, display: true, animate: true)
        } else {
          window.setContentSize(size)
        }
      }
    }
  }
}
