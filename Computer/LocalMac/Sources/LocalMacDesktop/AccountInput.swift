import AppKit
import LocalMacCore

/// Normal desktop events enter this helper's verified background session.
/// Never use the HID tap, which feeds the physical console.
final class AccountInput {
    let session: LocalMacSession
    private let source = CGEventSource(stateID: .privateState)
    private var buttons: Set<Int> = []
    private var keys: Set<UInt16> = []
    private var lastPoint = CGPoint.zero
    init(session: LocalMacSession) { self.session = session }

    private func send(_ event: CGEvent?) throws {
        guard let event else { throw LocalMacError("Cannot create a desktop input event.") }
        try session.verifyCurrent()
        event.post(tap: .cgSessionEventTap)
    }
    func post(_ input: LocalMacInput, bounds: CGRect) throws {
        try session.verifyCurrent()
        guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else {
            throw LocalMacError(LocalMacStatus.inputPermissionError)
        }
        if input.kind == .reset {
            for key in keys.sorted() { try send(CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)) }
            keys.removeAll()
            for button in buttons.sorted() {
                let type: CGEventType = button == 0 ? .leftMouseUp : button == 1 ? .rightMouseUp : .otherMouseUp
                try send(CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: lastPoint,
                                 mouseButton: CGMouseButton(rawValue: UInt32(button))!))
            }
            buttons.removeAll()
            return
        }
        if [.keyDown, .keyUp, .flagsChanged, .text].contains(input.kind) {
            if input.kind == .text {
                let text = Array((input.text ?? "").utf16)
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down)
                    event?.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text)
                    try send(event)
                }
            } else {
                let event = CGEvent(keyboardEventSource: source, virtualKey: input.key, keyDown: input.kind == .keyDown)
                if input.kind == .flagsChanged { event?.type = .flagsChanged }
                event?.flags = CGEventFlags(rawValue: input.flags)
                if input.kind == .keyDown { keys.insert(input.key) }
                else if input.kind == .keyUp { keys.remove(input.key) }
                else {
                    // Include modifier keys in focus-loss cleanup; a redundant
                    // release is harmless and cannot leave a modifier held.
                    keys.insert(input.key)
                }
                try send(event)
            }
            return
        }
        guard let point = session.account.display.desktopPoint(x: input.x, y: input.y, bounds: bounds,
                                                               clamp: !buttons.isEmpty) else { return }
        let delta = CGPoint(x: point.x - lastPoint.x, y: point.y - lastPoint.y)
        lastPoint = point
        let button = CGMouseButton(rawValue: UInt32(input.button))!
        let event: CGEvent?
        switch input.kind {
        case .scroll:
            event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                            wheel1: Int32(input.scroll), wheel2: 0, wheel3: 0)
            event?.location = point
        default:
            let type: CGEventType
            if input.kind == .down {
                buttons.insert(input.button)
                type = button == .left ? .leftMouseDown : button == .right ? .rightMouseDown : .otherMouseDown
            } else if input.kind == .up {
                guard buttons.remove(input.button) != nil else { return }
                type = button == .left ? .leftMouseUp : button == .right ? .rightMouseUp : .otherMouseUp
            } else if buttons.contains(input.button) {
                type = button == .left ? .leftMouseDragged : button == .right ? .rightMouseDragged : .otherMouseDragged
            } else { type = .mouseMoved }
            event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: button)
            event?.setIntegerValueField(.mouseEventClickState, value: Int64(input.clickCount))
            event?.setIntegerValueField(.mouseEventDeltaX, value: Int64(delta.x.rounded()))
            event?.setIntegerValueField(.mouseEventDeltaY, value: Int64(delta.y.rounded()))
            event?.setDoubleValueField(.mouseEventPressure, value: buttons.isEmpty ? 0 : 1)
        }
        event?.flags = CGEventFlags(rawValue: input.flags)
        try send(event)
    }
}
