import AppKit
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle

/// In-process native controls hosted in windows that are never ordered onscreen.
@MainActor class HiddenViewTests: XCTestCase {
    func fixture() throws -> StoreFixture {
        let f = try StoreFixture(); addTeardownBlock { @MainActor in f.cleanUp() }; return f
    }
    func host<V: View>(_ view: V) -> NSHostingView<V> {
        _ = NSApplication.shared
        // SwiftUI creates virtual controls lazily. This application attribute
        // exposes them for the fixture without changing system preferences.
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 700, height: 800),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Noodle settings test fixture"
        window.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: view); window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        XCTAssertFalse(window.isVisible)
        addTeardownBlock { @MainActor in
            window.close(); window.contentView = nil
            NSApp.accessibilitySetValue(previous, forAttribute: enhanced)
        }
        return hosting
    }
    func attribute(_ node: NSObject, _ key: NSAccessibility.Attribute) -> Any? {
        if let value = node.accessibilityAttributeValue(key) { return value }
        let names: [NSAccessibility.Attribute: String] = [.children: "accessibilityChildren", .title: "accessibilityTitle",
            .description: "accessibilityLabel", .value: "accessibilityValue", .enabled: "isAccessibilityEnabled", .role: "accessibilityRole"]
        let name = names[key] ?? (key.rawValue == "AXChildrenInNavigationOrder" ? "accessibilityChildrenInNavigationOrder" : "")
        guard !name.isEmpty, node.responds(to: NSSelectorFromString(name)) else { return nil }
        return node.value(forKey: name == "isAccessibilityEnabled" ? "accessibilityEnabled" : name)
    }
    func elements(_ root: AnyObject) -> [NSObject] {
        var pending: [AnyObject] = [root], visited = Set<ObjectIdentifier>(), result: [NSObject] = []
        while let object = pending.popLast() {
            guard visited.insert(ObjectIdentifier(object)).inserted else { continue }
            if let node = object as? NSObject {
                result.append(node)
                for key in [NSAccessibility.Attribute.children, NSAccessibility.Attribute(rawValue: "AXChildrenInNavigationOrder")] {
                    pending.append(contentsOf: (attribute(node, key) as? [AnyObject]) ?? [])
                }
            }
            if let view = object as? NSView { pending.append(contentsOf: view.subviews) }
        }
        return result
    }
    func labels(_ node: NSObject) -> [String] {
        [attribute(node, .title), attribute(node, .description), attribute(node, .value)].compactMap { $0 as? String }
    }
    final func wait(_ predicate: @escaping () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() {
            guard ContinuousClock.now < end else { XCTFail("Native control did not settle"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func control(_ name: String, in root: NSView) async throws -> NSObject {
        var found: NSObject?
        do {
            try await wait {
                root.layoutSubtreeIfNeeded()
                found = self.elements(root).first { self.matches(name, node: $0) }
                return found != nil
            }
        } catch {
            print("Missing control: \(name). Native tree: " + describe(root))
            throw error
        }
        return try XCTUnwrap(found)
    }
    func matches(_ name: String, node: NSObject) -> Bool {
        labels(node).contains { $0 == name || $0.components(separatedBy: ", ").contains(name) }
    }
    func hasControl(_ name: String, in root: NSView) -> Bool { elements(root).contains { matches(name, node: $0) } }
    func adjust(_ node: NSObject, increasing: Bool) -> Bool {
        let selector = NSSelectorFromString(increasing ? "accessibilityPerformIncrement" : "accessibilityPerformDecrement")
        guard node.responds(to: selector) else { return false }
        typealias Action = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(node.method(for: selector), to: Action.self)(node, selector)
    }
    func describe(_ root: NSView) -> String {
        elements(root).map { "\(type(of: $0)) [\(attribute($0, .role) ?? "?")]: \(labels($0))" }.joined(separator: "\n")
    }
    func enabled(_ node: NSObject) -> Bool { attribute(node, .enabled) as? Bool == true }
    func press(_ node: NSObject) {
        // SwiftUI's virtual nodes expose this public selector without always
        // declaring the corresponding Objective-C protocol conformance.
        let selector = NSSelectorFromString("accessibilityPerformPress")
        if node.responds(to: selector) {
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            _ = unsafeBitCast(node.method(for: selector), to: Press.self)(node, selector)
        } else { node.accessibilityPerformAction(.press) }
    }
    func edit(_ field: NSTextField, text: String) {
        field.stringValue = text
        field.delegate?.controlTextDidChange?(.init(name: NSControl.textDidChangeNotification, object: field))
    }
    func textField(_ placeholder: String, in root: NSView) async throws -> NSTextField {
        var field: NSTextField?
        try await wait {
            field = self.elements(root).compactMap { $0 as? NSTextField }.first { $0.placeholderString == placeholder }
            return field != nil
        }
        return try XCTUnwrap(field)
    }
    func nameField(in root: NSView, name: String) async throws -> NSTextField {
        var field: NSTextField?
        try await wait { field = self.elements(root).compactMap { $0 as? NSTextField }.first { $0.isEditable && $0.stringValue == name }; return field != nil }
        return try XCTUnwrap(field)
    }

}
