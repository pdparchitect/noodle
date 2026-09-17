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
        var rootElement: AXUIElement? = nil
    }
    /// Query AXWindows, not the raw WindowServer list: the latter also contains
    /// menus, tooltips, capture indicators and other non-root surfaces.
    static func visible(session: LocalMacSession, displayBounds: CGRect, pid onlyPID: Int32? = nil) -> [Focus] {
        guard (try? session.verifyCurrent()) != nil, AXIsProcessTrusted(), !displayBounds.isEmpty else { return [] }
        let records = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let candidates = records.compactMap { record -> LocalMacWindowMatch.Candidate? in
            guard let id = record[kCGWindowNumber as String] as? UInt32,
                  let pid = record[kCGWindowOwnerPID as String] as? Int32,
                  onlyPID == nil || onlyPID == pid,
                  let dictionary = record[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary),
                  bounds.intersects(displayBounds) else { return nil }
            return .init(id: id, pid: pid, title: record[kCGWindowName as String] as? String ?? "", bounds: bounds)
        }
        let rootIDs = Set(records.compactMap { record -> UInt32? in
            guard record[kCGWindowLayer as String] as? Int == 0 else { return nil }
            return record[kCGWindowNumber as String] as? UInt32
        })
        var pids: [Int32] = []
        for candidate in candidates where !pids.contains(candidate.pid) { pids.append(candidate.pid) }
        var result: [Focus] = []
        for pid in pids where NLMPIDBelongsToUser(pid, session.account.uid) {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 0.05)
            guard var windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] else { continue }
            if let focused = element(attribute(app, kAXFocusedWindowAttribute)), !windows.contains(where: { CFEqual($0, focused) }) {
                windows.append(focused)
            }
            let deadline = ContinuousClock.now.advanced(by: .milliseconds(400))
            var matches: [(AXUIElement, LocalMacWindow)] = []
            var nodes: [(AXUIElement, LocalMacWindowRoot.Node<AXUIElement>)] = []
            var sheetOwners: [(AXUIElement, AXUIElement)] = []
            func readNode(_ value: AXUIElement) -> LocalMacWindowRoot.Node<AXUIElement>? {
                if let cached = nodes.first(where: { CFEqual($0.0, value) }) { return cached.1 }
                guard ContinuousClock.now < deadline, var result = node(value) else { return nil }
                if result.isTransient, let owner = sheetOwners.first(where: { CFEqual($0.0, value) }) {
                    result.window = owner.1
                }
                nodes.append((value, result)); return result
            }
            // Attached sheets can appear only as direct AX children. Do not
            // walk the document's controls or make each child its own preview.
            var index = 0
            while index < windows.count, index < 256, ContinuousClock.now < deadline {
                let window = windows[index]; index += 1
                AXUIElementSetMessagingTimeout(window, 0.05)
                let children = attribute(window, kAXChildrenAttribute) as? [AXUIElement] ?? []
                for child in children.prefix(64) {
                    guard ContinuousClock.now < deadline else { break }
                    AXUIElementSetMessagingTimeout(child, 0.05)
                    let role = attribute(child, kAXRoleAttribute) as? String
                    guard role == kAXSheetRole || role == kAXDrawerRole || role == kAXPopoverRole else { continue }
                    sheetOwners.append((child, window))
                    if !windows.contains(where: { CFEqual($0, child) }) { windows.append(child) }
                }
            }
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Window"
            func matchWindow(_ value: AXUIElement) -> LocalMacWindow? {
                if let cached = matches.first(where: { CFEqual($0.0, value) }) { return cached.1 }
                guard ContinuousClock.now < deadline,
                      let result = match(value, pid: pid, name: name, displayBounds: displayBounds, candidates: candidates) else { return nil }
                matches.append((value, result)); return result
            }
            let families: [LocalMacWindowRoot.Selection<LocalMacWindow>] = LocalMacWindowRoot.families(
                elements: Array(windows.prefix(256)), pid: pid, mainWindow: element(attribute(app, kAXMainWindowAttribute)),
                same: { CFEqual($0, $1) }, read: readNode, match: matchWindow, sameWindow: { $0.hasSameIdentity(as: $1) })
            for family in families where rootIDs.contains(family.root.id) {
                result.append(.init(window: family.root, relatedWindowIDs: Set(family.windows.map(\.id)),
                                    rootElement: matches.first(where: { $0.1.id == family.root.id })?.0))
            }
        }
        // Preserve guest stacking order, including separate documents in one app.
        let order = Dictionary(candidates.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: min)
        return result.sorted { order[$0.window.id, default: Int.max] < order[$1.window.id, default: Int.max] }
    }

    static func activate(_ window: LocalMacWindow, session: LocalMacSession, displayBounds: CGRect) async throws {
        if let focused = read(session: session, displayBounds: displayBounds), focused.window.hasSameIdentity(as: window) { return }
        guard let target = visible(session: session, displayBounds: displayBounds, pid: window.pid)
            .first(where: { $0.window.hasSameIdentity(as: window) }), let root = target.rootElement else {
            throw LocalMacError("This window is no longer available.")
        }
        try session.verifyCurrent()
        let app = AXUIElementCreateApplication(window.pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        AXUIElementSetMessagingTimeout(root, 0.05)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(root, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(root, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(root, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        // Raising can be asynchronous. Verify the exact root, not just its PID,
        // before allowing keyboard or pointer input into the shared session.
        for attempt in 0..<5 {
            if attempt > 0 { try await Task.sleep(for: .milliseconds(30)) }
            try session.verifyCurrent()
            if let focused = read(session: session, displayBounds: displayBounds), focused.window.hasSameIdentity(as: window) { return }
        }
        throw LocalMacError("This window could not be activated. Select it on the desktop and try again.")
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
        return .init(pid: pid, role: role, subrole: subrole, modal: entries[4] as? Bool == true,
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
