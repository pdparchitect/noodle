import AppKit
import SwiftUI
import XCTest
import NoodleCore
@testable import Noodle

/// Uses the native accessibility/event interfaces of this test process only.
/// No external accessibility permission or real harness account is needed.
@MainActor final class SettingsInteractionTests: XCTestCase {
    private func fixture() throws -> StoreFixture {
        let f = try StoreFixture(); addTeardownBlock { @MainActor in f.cleanUp() }; return f
    }
    private func host<V: View>(_ view: V) -> NSHostingView<V> {
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
    private func attribute(_ node: NSObject, _ key: NSAccessibility.Attribute) -> Any? {
        if let value = node.accessibilityAttributeValue(key) { return value }
        let names: [NSAccessibility.Attribute: String] = [.children: "accessibilityChildren", .title: "accessibilityTitle",
            .description: "accessibilityLabel", .enabled: "isAccessibilityEnabled", .role: "accessibilityRole"]
        let name = names[key] ?? (key.rawValue == "AXChildrenInNavigationOrder" ? "accessibilityChildrenInNavigationOrder" : "")
        guard !name.isEmpty, node.responds(to: NSSelectorFromString(name)) else { return nil }
        return node.value(forKey: name == "isAccessibilityEnabled" ? "accessibilityEnabled" : name)
    }
    private func elements(_ root: AnyObject) -> [NSObject] {
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
    private func labels(_ node: NSObject) -> [String] {
        [attribute(node, .title), attribute(node, .description)].compactMap { $0 as? String }
    }
    private func wait(_ predicate: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() {
            guard ContinuousClock.now < end else { XCTFail("Native control did not settle"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    private func control(_ name: String, in root: NSView) async throws -> NSObject {
        var found: NSObject?
        try await wait {
            root.layoutSubtreeIfNeeded()
            found = self.elements(root).first { self.labels($0).contains(name) }
            return found != nil
        }
        return try XCTUnwrap(found)
    }
    private func enabled(_ node: NSObject) -> Bool { attribute(node, .enabled) as? Bool == true }
    private func press(_ node: NSObject) {
        // SwiftUI's virtual nodes expose this public selector without always
        // declaring the corresponding Objective-C protocol conformance.
        let selector = NSSelectorFromString("accessibilityPerformPress")
        if node.responds(to: selector) {
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            _ = unsafeBitCast(node.method(for: selector), to: Press.self)(node, selector)
        } else { node.accessibilityPerformAction(.press) }
    }
    private func edit(_ field: NSTextField, text: String) {
        field.stringValue = text
        field.delegate?.controlTextDidChange?(.init(name: NSControl.textDidChangeNotification, object: field))
    }
    private func nameField(in root: NSView, name: String) async throws -> NSTextField {
        var field: NSTextField?
        try await wait { field = self.elements(root).compactMap { $0 as? NSTextField }.first { $0.isEditable && $0.stringValue == name }; return field != nil }
        return try XCTUnwrap(field)
    }

    func testEditorSaveButtonPersistsEditedName() async throws {
        let f = try fixture(), editor = host(EditBotSheet(agent: f.a).environment(f.store))
        let field = try await nameField(in: editor, name: f.a.displayName)
        edit(field, text: "Renamed through UI")
        press(try await control("Save", in: editor))
        try await wait { f.store.agents.first { $0.id == f.a.id }?.displayName == "Renamed through UI" }
        XCTAssertEqual(try f.repository.loadAgents().first { $0.id == f.a.id }?.displayName, "Renamed through UI")
    }

    func testEditorFailedSaveKeepsChangesAndRetryPersistsWithoutDuplicate() async throws {
        let f = try fixture(), process = try f.runtime.start(f.a)
        let editor = host(EditBotSheet(agent: f.a).environment(f.store))
        let field = try await nameField(in: editor, name: f.a.displayName)
        edit(field, text: "Retained edit")
        let configuration = f.repository.storage(for: f.a.id).configuration
        let original = try Data(contentsOf: configuration)
        try FileManager.default.removeItem(at: configuration)
        try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: false)
        press(try await control("Save", in: editor))
        try await wait { f.store.errorMessage != nil }
        XCTAssertEqual(field.stringValue, "Retained edit"); XCTAssertEqual(process.stops, 0)
        XCTAssertEqual(f.store.agents.first { $0.id == f.a.id }?.displayName, f.a.displayName)
        try FileManager.default.removeItem(at: configuration); try original.write(to: configuration)
        press(try await control("Save", in: editor))
        try await wait { f.store.agents.first { $0.id == f.a.id }?.displayName == "Retained edit" }
        XCTAssertEqual(try f.repository.loadAgents().count, 2)
    }

    func testEditorRejectsBlankNameAndCancelDoesNotPersistDraft() async throws {
        let f = try fixture(), editor = host(EditBotSheet(agent: f.a).environment(f.store))
        let field = try await nameField(in: editor, name: f.a.displayName)
        edit(field, text: "  ")
        let save = try await control("Save", in: editor)
        try await wait { !self.enabled(save) }
        edit(field, text: "Cancelled edit")
        press(try await control("Cancel", in: editor))
        XCTAssertEqual(try f.repository.loadAgents().first { $0.id == f.a.id }?.displayName, f.a.displayName)
    }
}
