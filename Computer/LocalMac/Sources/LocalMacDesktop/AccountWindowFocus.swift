import AppKit
import ApplicationServices
import LocalMacCore
import LocalMacPrivate
import OSLog

@MainActor enum AccountWindowFocus {
    private static let logger = Logger(subsystem: "com.pdparchitect.noodle.computer", category: "WindowFocus")
    private static var lastDiagnostic: String?
    private static func report(_ message: String) {
        guard lastDiagnostic != message else { return }
        lastDiagnostic = message
        logger.notice("\(message, privacy: .public)")
    }
    struct Focus {
        var window: LocalMacWindow
        var relatedWindowIDs: Set<UInt32>
    }
    static func read(session: LocalMacSession, displayBounds: CGRect) -> Focus? {
        guard (try? session.verifyCurrent()) != nil else {
            report("Focus unavailable outside the assigned background session."); return nil
        }
        guard AXIsProcessTrusted() else {
            report("Focus requires accessibility access."); return nil
        }
        guard !displayBounds.isEmpty else {
            report("Focus is waiting for the account display."); return nil
        }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let candidates = windows.compactMap { record -> LocalMacWindowMatch.Candidate? in
            guard let id = record[kCGWindowNumber as String] as? UInt32,
                  let pid = record[kCGWindowOwnerPID as String] as? Int32,
                  let dictionary = record[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return nil }
            return .init(id: id, pid: pid, title: record[kCGWindowName as String] as? String ?? "", bounds: rect)
        }
        let workspacePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let visibleApps = windows.compactMap { record -> LocalMacApplicationFocus.Candidate? in
            guard let pid = record[kCGWindowOwnerPID as String] as? Int32,
                  let layer = record[kCGWindowLayer as String] as? Int,
                  let dictionary = record[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  bounds.intersects(displayBounds) else { return nil }
            return .init(pid: pid, layer: layer)
        }
        guard let pid = focusedPID(session: session, workspacePID: workspacePID, candidates: visibleApps) else {
            report("No verified frontmost app is available in this account."); return nil
        }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Window"
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.25)
        guard let focused = element(attribute(application, kAXFocusedWindowAttribute)) else {
            report("The active app has no readable focused window."); return nil
        }
        // Preserve the original focused-window path before optional ancestry
        // reads consume their time budget or encounter unsupported AX attributes.
        let focusedMatch = match(focused, pid: pid, name: name, displayBounds: displayBounds, candidates: candidates)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(250))
        let selection = LocalMacWindowRoot.resolve(focused: focused, pid: pid,
            mainWindow: element(attribute(application, kAXMainWindowAttribute)), same: { CFEqual($0, $1) }, read: { value in
                guard ContinuousClock.now < deadline else { return nil }
                return node(value)
            })
        guard let captured = LocalMacWindowRoot.capture(focused: focused, selection: selection,
            same: { CFEqual($0, $1) }, match: { value in
                if CFEqual(value, focused) { return focusedMatch }
                guard ContinuousClock.now < deadline else { return nil }
                return match(value, pid: pid, name: name, displayBounds: displayBounds, candidates: candidates)
            }) else {
                report("No focused window matches this account's display."); return nil
            }
        report(workspacePID == nil ? "Focus recovered using the account app's accessibility frontmost state."
               : selection == nil ? "Focus available using the verified focused window; ancestry unavailable."
               : "Focus available using verified window ownership.")
        return Focus(window: captured.root, relatedWindowIDs: Set(captured.windows.map(\.id)))
    }
    static func isFrontmost(_ pid: Int32, session: LocalMacSession) -> Bool {
        guard (try? session.verifyCurrent()) != nil, AXIsProcessTrusted() else { return false }
        return focusedPID(session: session, workspacePID: NSWorkspace.shared.frontmostApplication?.processIdentifier,
                          candidates: [.init(pid: pid, layer: 0)]) == pid
    }
    private static func focusedPID(session: LocalMacSession, workspacePID: Int32?,
                                   candidates: [LocalMacApplicationFocus.Candidate]) -> Int32? {
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(200))
        return LocalMacApplicationFocus.resolve(workspacePID: workspacePID, candidates: candidates,
            belongsToAccount: { NLMPIDBelongsToUser($0, session.account.uid) }, isFrontmost: { pid in
                guard ContinuousClock.now < deadline else { return nil }
                let application = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(application, 0.05)
                return attribute(application, kAXFrontmostAttribute) as? Bool
            })
    }
    private static func match(_ element: AXUIElement, pid: Int32, name: String, displayBounds: CGRect,
                              candidates: [LocalMacWindowMatch.Candidate]) -> LocalMacWindow? {
        AXUIElementSetMessagingTimeout(element, 0.25)
        guard let position = attribute(element, kAXPositionAttribute), CFGetTypeID(position) == AXValueGetTypeID(),
              let size = attribute(element, kAXSizeAttribute), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(position, to: AXValue.self), .cgPoint, &point),
              AXValueGetValue(unsafeBitCast(size, to: AXValue.self), .cgSize, &extent) else { return nil }
        let bounds = CGRect(origin: point, size: extent)
        guard bounds.width > 0, bounds.height > 0, bounds.intersects(displayBounds) else { return nil }
        let title = attribute(element, kAXTitleAttribute) as? String ?? ""
        guard let id = LocalMacWindowMatch.find(pid: pid, title: title, bounds: bounds, in: candidates) else { return nil }
        return .init(id: id, pid: pid, title: title, application: name)
    }
    private static func node(_ value: AXUIElement) -> LocalMacWindowRoot.Node<AXUIElement>? {
        // AX timeouts apply to this exact object; the application's timeout
        // does not propagate to the window or its parents.
        AXUIElementSetMessagingTimeout(value, 0.05)
        var pid: pid_t = 0
        guard AXUIElementGetPid(value, &pid) == .success else { return nil }
        let names = [kAXRoleAttribute, kAXSubroleAttribute, kAXParentAttribute, kAXWindowAttribute, kAXModalAttribute]
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(value, names as CFArray, [], &values) == .success,
              let entries = values as? [AnyObject], entries.count == names.count,
              let role = entries[0] as? String else { return nil }
        if role == kAXApplicationRole { return .init(pid: pid, isWindow: false) }
        let subrole = entries[1] as? String ?? ""
        let isWindow = [kAXWindowRole, kAXSheetRole, kAXDrawerRole, kAXPopoverRole].contains(role)
        let transient = [kAXSheetRole, kAXDrawerRole, kAXPopoverRole].contains(role) ||
            [kAXDialogSubrole, kAXSystemDialogSubrole, kAXFloatingWindowSubrole, kAXSystemFloatingWindowSubrole].contains(subrole) ||
            (entries[4] as? Bool == true)
        return .init(pid: pid, isWindow: isWindow, isTransient: isWindow && transient,
                     parent: element(entries[2]), window: element(entries[3]))
    }
    private static func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }
}
