import AppKit
import ApplicationServices
import NoodleContextFieldsTools
import NoodleCore
import ScreenCaptureKit

/// What was in front when Choose Conversation with Context was pressed: the app, its window and page, and
/// the field being typed in. It waits in the picked conversation's message field as one annotation: the
/// window with the field outlined, quoting its text, and a comment saying where it came from.
struct FocusedContext: Equatable, Sendable {
    var appName: String
    var bundleIdentifier: String?
    var windowTitle: String?
    var pageURL: String?
    var fieldLabel: String?
    var fieldRole: String?
    var text: String?
    var selection: String?
    /// Screen frames as Accessibility gives them, from the top-left.
    var fieldFrame: CGRect?
    var windowFrame: CGRect?

    /// A terminal's whole scrollback is a "field" too; past this, only the end is kept, where people type.
    static let textLimit = 20_000

    var title: String { windowTitle.flatMap { $0.isEmpty ? nil : $0 } ?? appName }

    private var selected: String? { selection.flatMap { $0.isEmpty ? nil : $0 } }
    private var fieldText: String? { text.flatMap { $0.isEmpty ? nil : $0 } }

    /// The selection, or else the field's text.
    var quote: String? {
        if let selected { return selected }
        return fieldText.map { $0.count > Self.textLimit ? String($0.suffix(Self.textLimit)) : $0 }
    }

    var comment: String {
        var lines = ["Context from \(appName)" + (windowTitle.flatMap { $0.isEmpty ? nil : ": \($0)" } ?? "")]
        if let pageURL, !pageURL.isEmpty { lines.append(pageURL) }
        let label = [fieldLabel, fieldRole.map { "(\($0))" }].compactMap { $0.flatMap { $0.isEmpty || $0 == "()" ? nil : $0 } }
        if !label.isEmpty { lines.append("Field: " + label.joined(separator: " ") + (selected == nil ? "" : ", selected text quoted")) }
        if selected == nil, let fieldText, fieldText.count > Self.textLimit {
            let left = (fieldText.count - Self.textLimit).formatted(.number.locale(Locale(identifier: "en_US")))
            lines.append("The first \(left) characters of the field are left out.")
        }
        return lines.joined(separator: "\n")
    }

    /// The field within the window, as a fraction of it from the bottom-left, as annotations mark regions.
    var region: AttachmentAnnotation.Region? {
        guard let fieldFrame, let windowFrame, windowFrame.width > 0, windowFrame.height > 0 else { return nil }
        let field = fieldFrame.intersection(windowFrame)
        guard !field.isNull, field.width > 0, field.height > 0 else { return nil }
        return .init(x: (field.minX - windowFrame.minX) / windowFrame.width, y: (windowFrame.maxY - field.maxY) / windowFrame.height,
                     width: field.width / windowFrame.width, height: field.height / windowFrame.height)
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
        if let window = element(app, kAXFocusedWindowAttribute) {
            context.windowTitle = string(window, kAXTitleAttribute)
            context.windowFrame = frame(window)
        }
        // Passwords are never read, nor what looks like card details, a code or an identity number.
        guard let field = element(app, kAXFocusedUIElementAttribute),
              string(field, kAXSubroleAttribute) != kAXSecureTextFieldSubrole,
              !ContextFieldReader.isSensitive(field, value: string(field, kAXValueAttribute)) else { return context }
        context.text = string(field, kAXValueAttribute)
        context.selection = string(field, kAXSelectedTextAttribute)
        // A focused button or list is no field to quote.
        guard context.text != nil || context.selection != nil else { return context }
        context.fieldRole = string(field, kAXRoleDescriptionAttribute)
        context.fieldFrame = frame(field)
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

    private nonisolated static func frame(_ element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var origin = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private nonisolated static func string(_ element: AXUIElement, _ name: String) -> String? {
        switch attribute(element, name) {
        case let text as String: text
        case let text as NSAttributedString: text.string
        default: nil
        }
    }
}

/// The form around the focused field, or the field alone, kept so the bots the context is sent to can fill it.
/// Pages and windows say nothing about a form's purpose to Accessibility, so a web `<form>` is the only form found.
enum ContextFieldReader {
    /// Enough for a long form; a whole page of controls would flood the context.
    static let limit = 50
    private static let timeout: Float = 1

    nonisolated static func capture(pid: pid_t, context: FocusedContext) -> ContextFieldCapture? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        guard let focused = element(app, kAXFocusedUIElementAttribute), kind(focused) != nil else { return nil }
        var scope = focused
        var current = element(focused, kAXParentAttribute)
        for _ in 0..<40 {
            guard let ancestor = current, string(ancestor, kAXRoleAttribute) != "AXWebArea" else { break }
            if string(ancestor, kAXSubroleAttribute) == "AXLandmarkForm" { scope = ancestor; break }
            current = element(ancestor, kAXParentAttribute)
        }
        var found: [(ContextField, AXUIElement)] = [], withheld: [String] = []
        collect(scope, into: &found, withheld: &withheld)
        guard !found.isEmpty else { return nil }
        return ContextFieldCapture(app: context.appName, window: context.windowTitle, page: context.pageURL,
                                   fields: found.map(\.0), withheld: withheld,
                                   surface: AccessibilityFields(Dictionary(found.map { ($0.0.id, $0.1) }) { $1 }))
    }

    private static func collect(_ element: AXUIElement, into found: inout [(ContextField, AXUIElement)], withheld: inout [String], depth: Int = 0) {
        guard found.count < limit, depth < 40 else { return }
        if let kind = kind(element) {
            AXUIElementSetMessagingTimeout(element, timeout)
            let label = label(element), value = value(element, kind: kind)
            // Left out whole: neither read nor written. The bot is told the label, or that a field was left out.
            if ContextFieldSensitivity.isSensitive(label: label, identifier: string(element, "AXDOMIdentifier"), value: value) {
                withheld.append(label ?? "Unlabelled field")
                return
            }
            let options = kind == .choice ? children(element).flatMap(children).compactMap { string($0, kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 } } : []
            found.append((ContextField(id: "f\(found.count + 1)", label: label, kind: kind, value: value, options: options), element))
            return
        }
        for child in children(element) { collect(child, into: &found, withheld: &withheld, depth: depth + 1) }
    }

    static func isSensitive(_ element: AXUIElement, value: String?) -> Bool {
        ContextFieldSensitivity.isSensitive(label: label(element), identifier: string(element, "AXDOMIdentifier"), value: value)
    }

    /// Passwords are never captured, nor a rich editor's own toolbar buttons.
    static func kind(_ element: AXUIElement) -> ContextFieldKind? {
        let subrole = string(element, kAXSubroleAttribute)
        guard subrole != kAXSecureTextFieldSubrole, (attribute(element, kAXEnabledAttribute) as? Bool) != false else { return nil }
        switch string(element, kAXRoleAttribute) {
        case kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole: return .text
        case kAXCheckBoxRole: return subrole == kAXToggleSubrole || subrole == "AXToggleButton" ? nil : .checkbox
        case kAXRadioButtonRole: return .radio
        case kAXPopUpButtonRole: return .choice
        case "AXDateField", "AXTimeField": return .date
        default: return nil
        }
    }

    /// Nil once the field or its app is gone; toggles read "true" or "false".
    static func value(_ element: AXUIElement, kind: ContextFieldKind) -> String? {
        var role: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success else { return nil }
        if kind == .checkbox || kind == .radio { return (attribute(element, kAXValueAttribute) as? NSNumber)?.boolValue == true ? "true" : "false" }
        return string(element, kAXValueAttribute) ?? ""
    }

    /// Its own label, or else the text just before it, where a form without labels shows one.
    static func label(_ element: AXUIElement) -> String? {
        if let own = [kAXTitleAttribute, kAXDescriptionAttribute, kAXPlaceholderValueAttribute].lazy
            .compactMap({ string(element, $0) }).first(where: { !$0.isEmpty }) { return own }
        if let titled = self.element(element, kAXTitleUIElementAttribute),
           let text = string(titled, kAXValueAttribute) ?? string(titled, kAXTitleAttribute), !text.isEmpty { return text }
        var child = element
        for _ in 0..<2 {
            guard let parent = self.element(child, kAXParentAttribute) else { return nil }
            let siblings = children(parent)
            if let index = siblings.firstIndex(where: { CFEqual($0, child) }) {
                for sibling in siblings[..<index].reversed().prefix(3) {
                    if let text = lastText(sibling) { return text }
                    if kind(sibling) != nil { return nil }
                }
            }
            child = parent
        }
        return nil
    }

    private static func lastText(_ element: AXUIElement, depth: Int = 0) -> String? {
        if string(element, kAXRoleAttribute) == kAXStaticTextRole, let text = string(element, kAXValueAttribute)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
        guard depth < 3 else { return nil }
        return children(element).reversed().lazy.compactMap { lastText($0, depth: depth + 1) }.first
    }

    static func children(_ element: AXUIElement) -> [AXUIElement] { (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }

    static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        switch attribute(element, name) {
        case let text as String: text
        case let text as NSAttributedString: text.string
        default: nil
        }
    }
}

/// Captured controls, written through Accessibility. The app keeps its focus: nothing is typed or clicked
/// for the person. Chromium answers only while its pages are kept ready, which Choose Conversation with
/// Context already does for the apps that come to the front.
final class AccessibilityFields: ContextFieldSurface, @unchecked Sendable {
    private let elements: [String: AXUIElement]
    init(_ elements: [String: AXUIElement]) { self.elements = elements }

    func value(of field: String) async -> String? {
        guard let element = elements[field], let kind = ContextFieldReader.kind(element) else { return nil }
        return ContextFieldReader.value(element, kind: kind)
    }

    func setText(_ text: String, of field: String) async {
        guard let element = elements[field] else { return }
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString)
        await settle(field) { $0 == text }
    }

    /// Setting a toggle's value does nothing in browsers; pressing it works in every app.
    func press(_ field: String) async {
        guard let element = elements[field] else { return }
        let before = await value(of: field)
        AXUIElementPerformAction(element, kAXPressAction as CFString)
        await settle(field) { $0 != before }
    }

    /// A page in a hidden tab answers with its old value for a moment after a write.
    private func settle(_ field: String, until done: (String?) -> Bool) async {
        for _ in 0..<15 {
            if done(await value(of: field)) { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// A browser menu takes no value: it is opened, which shows it briefly, and the option is pressed.
    /// A menu in a hidden tab does not open, so it stays as it was and the bot is told.
    func choose(_ option: String, in field: String) async {
        guard let element = elements[field] else { return }
        AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, option as CFString)
        try? await Task.sleep(for: .milliseconds(150))
        guard await value(of: field) != option else { return }
        AXUIElementPerformAction(element, kAXPressAction as CFString)
        var item: AXUIElement?
        for _ in 0..<10 where item == nil {
            try? await Task.sleep(for: .milliseconds(100))
            item = ContextFieldReader.children(element).flatMap(ContextFieldReader.children).first {
                ContextFieldReader.string($0, kAXTitleAttribute) == option || ContextFieldReader.string($0, kAXValueAttribute) == option
            }
        }
        if let item {
            AXUIElementPerformAction(item, kAXPressAction as CFString)
            await settle(field) { $0 == option }
        } else if let menu = ContextFieldReader.children(element).first(where: { ContextFieldReader.string($0, kAXRoleAttribute) == kAXMenuRole }) {
            AXUIElementPerformAction(menu, kAXCancelAction as CFString)
        }
    }
}

extension FocusedContext {
    init(appName: String, bundleIdentifier: String?) {
        self.init(appName: appName, bundleIdentifier: bundleIdentifier, windowTitle: nil, pageURL: nil,
                  fieldLabel: nil, fieldRole: nil, text: nil, selection: nil, fieldFrame: nil, windowFrame: nil)
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
