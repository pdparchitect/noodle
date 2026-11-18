import AppKit
import ApplicationServices
import ScreenCaptureKit

/// What was in front when Choose Conversation with Context was pressed: the app, its window and page, and
/// the field being typed in. It waits in the picked conversation's message field as a note beside a picture
/// of the window.
struct FocusedContext: Equatable, Sendable {
    var appName: String
    var bundleIdentifier: String?
    var windowTitle: String?
    var pageURL: String?
    var fieldLabel: String?
    var fieldRole: String?
    var text: String?
    var selection: String?

    /// A terminal's whole scrollback is a "field" too; past this, only the end is kept, where people type.
    static let textLimit = 20_000

    var title: String { windowTitle.flatMap { $0.isEmpty ? nil : $0 } ?? appName }

    var note: String {
        var note = "# Context from \(appName)\n"
        var details: [String] = []
        if let windowTitle, !windowTitle.isEmpty { details.append("- Window: \(windowTitle)") }
        if let pageURL, !pageURL.isEmpty { details.append("- Page: \(pageURL)") }
        switch (fieldLabel.flatMap { $0.isEmpty ? nil : $0 }, fieldRole.flatMap { $0.isEmpty ? nil : $0 }) {
        case let (label?, role?): details.append("- Field: \(label) (\(role))")
        case let (label?, nil), let (nil, label?): details.append("- Field: \(label)")
        case (nil, nil): break
        }
        if !details.isEmpty { note += "\n" + details.joined(separator: "\n") + "\n" }
        if let selection, !selection.isEmpty { note += "\n## Selected text\n\n" + Self.fenced(selection) + "\n" }
        if let text, !text.isEmpty {
            note += "\n## Field text\n\n"
            var kept = text
            if text.count > Self.textLimit {
                kept = String(text.suffix(Self.textLimit))
                let left = (text.count - Self.textLimit).formatted(.number.locale(Locale(identifier: "en_US")))
                note += "_\(left) earlier characters left out._\n\n"
            }
            note += Self.fenced(kept) + "\n"
        }
        return note
    }

    /// A fence longer than any run of backticks in the text, so the text cannot close it.
    private static func fenced(_ text: String) -> String {
        var longest = 0, run = 0
        for character in text {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: max(3, longest + 1))
        return fence + "\n" + text + "\n" + fence
    }
}

/// Reads another app's focused field through Accessibility. The sandbox reaches it through the one service
/// the entitlements name; without the person's permission every read comes back empty.
enum FocusedContextReader {
    /// Chromium builds its web pages for Accessibility only once a client asks, about two seconds later, so
    /// Noodle asks when one of these comes to the front.
    static let chromium: Set<String> = ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev",
        "com.google.Chrome.canary", "org.chromium.Chromium", "com.brave.Browser", "com.microsoft.edgemac",
        "com.vivaldi.Vivaldi", "company.thebrowser.Browser", "com.operasoftware.Opera"]

    /// A hung app answers nothing; Accessibility would otherwise wait six seconds for each read.
    private static let timeout: Float = 0.25

    /// True when Chromium was asked to keep its pages ready, which `release` undoes.
    nonisolated static func prepare(pid: pid_t, bundleIdentifier: String?) -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let app = application(pid)
        // Electron's own switch; other apps ignore it.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let bundleIdentifier, chromium.contains(bundleIdentifier) else { return false }
        // Chromium answers kAXErrorNotImplemented, yet acts on it.
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        return true
    }

    nonisolated static func release(pid: pid_t) {
        AXUIElementSetAttributeValue(application(pid), "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
    }

    nonisolated static func read(pid: pid_t, appName: String, bundleIdentifier: String?) -> FocusedContext {
        var context = FocusedContext(appName: appName, bundleIdentifier: bundleIdentifier)
        guard AXIsProcessTrusted() else { return context }
        let app = application(pid)
        if let window = element(app, kAXFocusedWindowAttribute) { context.windowTitle = string(window, kAXTitleAttribute) }
        // Passwords are never read.
        guard let field = element(app, kAXFocusedUIElementAttribute),
              string(field, kAXSubroleAttribute) != kAXSecureTextFieldSubrole else { return context }
        context.text = string(field, kAXValueAttribute)
        context.selection = string(field, kAXSelectedTextAttribute)
        // A focused button or list is no field to quote.
        guard context.text != nil || context.selection != nil else { return context }
        context.fieldRole = string(field, kAXRoleDescriptionAttribute)
        context.fieldLabel = [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute]
            .lazy.compactMap { string(field, $0) }.first { !$0.isEmpty }
        var current: AXUIElement? = field
        for _ in 0..<60 {
            guard let element = current else { break }
            if string(element, kAXRoleAttribute) == "AXWebArea" {
                context.pageURL = (attribute(element, "AXURL") as? URL)?.absoluteString
                break
            }
            current = self.element(element, kAXParentAttribute)
        }
        return context
    }

    private nonisolated static func application(_ pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        return app
    }

    private nonisolated static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private nonisolated static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    private nonisolated static func string(_ element: AXUIElement, _ name: String) -> String? {
        switch attribute(element, name) {
        case let text as String: text
        case let text as NSAttributedString: text.string
        default: nil
        }
    }
}

extension FocusedContext {
    init(appName: String, bundleIdentifier: String?) {
        self.init(appName: appName, bundleIdentifier: bundleIdentifier, windowTitle: nil, pageURL: nil,
                  fieldLabel: nil, fieldRole: nil, text: nil, selection: nil)
    }
}

/// A picture of an app's front window alone, so Noodle's own panels over it are left out.
enum WindowSnapshot {
    /// Large enough to read, small enough to send.
    static let longestEdge: CGFloat = 2400

    /// Nil without Screen Recording or a window on screen.
    static func capture(pid: pid_t) async -> CGImage? {
        guard CGPreflightScreenCaptureAccess(),
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              // Front to back, so the first is the one in use.
              let id = windows.first(where: {
                  ($0[kCGWindowOwnerPID as String] as? pid_t) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
                      && (($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0) }
                          .map { $0.width >= 40 && $0.height >= 40 } ?? false)
              })?[kCGWindowNumber as String] as? CGWindowID,
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.windowID == id }) else { return nil }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let size = filter.contentRect.size
        let scale = min(CGFloat(filter.pointPixelScale), longestEdge / max(1, size.width, size.height))
        configuration.width = max(1, Int((size.width * scale).rounded()))
        configuration.height = max(1, Int((size.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}
