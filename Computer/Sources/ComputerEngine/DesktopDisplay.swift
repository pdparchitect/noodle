import AppKit
import SwiftUI
import Virtualization

public struct VirtualMachineDisplay: NSViewRepresentable {
  let machine: VZVirtualMachine
  var resizes = true
  /// A Linux desktop: its size follows the setting at once, and ⌘C and ⌘V use the Mac clipboard.
  var native: NativeDisplay?
  /// The memberwise initializer, which Swift keeps internal unless written out.
  public init(machine: VZVirtualMachine, resizes: Bool = true, native: NativeDisplay? = nil) {
    self.machine = machine; self.resizes = resizes; self.native = native
  }
  public func makeNSView(context: Context) -> VZVirtualMachineView {
    let view = DesktopMachineView()
    view.virtualMachine = machine
    view.capturesSystemKeys = true
    view.native = native
    updateNSView(view, context: context)
    return view
  }
  public func updateNSView(_ view: VZVirtualMachineView, context: Context) {
    if view.virtualMachine !== machine { view.virtualMachine = machine }
    view.automaticallyReconfiguresDisplay = resizes
    (view as? DesktopMachineView)?.native = native
    let scale = view.window?.backingScaleFactor ?? 2
    native?.apply(resizes: resizes, viewPixels: CGSize(width: view.bounds.width * scale, height: view.bounds.height * scale))
  }
}

/// The view that shows a Linux desktop: VZ's own, or the one for the app's 3D GPU.
@MainActor public protocol DesktopDisplayView: NSView {
  var displayedMachine: VZVirtualMachine? { get }
  var followsWindowSize: Bool { get }
  /// Where ⌘C and ⌘V copy to and paste from.
  var pasteboard: NSPasteboard { get set }
}

/// The desktop's own view, which turns ⌘C and ⌘V, and Copy and Paste in the Edit menu,
/// into copy and paste between the Mac and the guest. The guest sees the Mac clipboard
/// only when someone pastes it.
final class DesktopMachineView: VZVirtualMachineView, DesktopDisplayView {
  var native: NativeDisplay?
  var pasteboard = NSPasteboard.general
  var displayedMachine: VZVirtualMachine? { virtualMachine }
  var followsWindowSize: Bool { automaticallyReconfiguresDisplay }

  // The Edit menu, and its ⌘C and ⌘V, reach the focused view as these actions.
  @objc func copy(_ sender: Any?) { transfer(copying: true) }
  @objc func paste(_ sender: Any?) { transfer(copying: false) }

  // Without a menu item the keys arrive here, where the guest would otherwise get them.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    guard let copying = clipboardKey(event) else { return super.performKeyEquivalent(with: event) }
    transfer(copying: copying)
    return true
  }

  override func keyDown(with event: NSEvent) {
    guard let copying = clipboardKey(event) else { return super.keyDown(with: event) }
    transfer(copying: copying)
  }

  private func clipboardKey(_ event: NSEvent) -> Bool? {
    guard native != nil, event.type == .keyDown,
          event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return nil }
    switch event.charactersIgnoringModifiers?.lowercased() {
    case "c": return true
    case "v": return false
    default: return nil
    }
  }

  private func transfer(copying: Bool) {
    guard let native else { return }
    let pasteboard = pasteboard
    Task { @MainActor in
      if !copying {
        guard let text = pasteboard.string(forType: .string) else { return }
        try? await native.surface.paste(text)
      } else if let text = try? await native.surface.copy(), !text.isEmpty {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
      }
    }
  }
}
