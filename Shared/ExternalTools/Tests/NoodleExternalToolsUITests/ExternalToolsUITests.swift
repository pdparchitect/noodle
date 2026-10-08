import AppKit
import NoodleExternalTools
@testable import NoodleExternalToolsUI
import SwiftUI
import Testing

/// Renders the question window and the Settings tab. Set NOODLE_EXTERNAL_UI_RENDERS to a folder to
/// keep the pictures for a look.
@MainActor @Suite struct ExternalToolsUITests {
    /// Drawn by AppKit, as on screen: lists and forms are AppKit views SwiftUI's ImageRenderer cannot draw.
    private func render(_ view: some View, _ name: String) throws -> CGImage {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .light))
        host.frame.size = host.fittingSize
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let image = try #require(bitmap.cgImage)
        if let folder = ProcessInfo.processInfo.environment["NOODLE_EXTERNAL_UI_RENDERS"] {
            let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            try data?.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
        return image
    }

    /// A warning makes the question taller rather than being cut off.
    @Test func aCautionGrowsTheQuestion() throws {
        let icon = NSWorkspace.shared.icon(forFile: "/bin/zsh")
        let plain = ExternalQuestion(icon: icon, title: "Allow “Claude Code” to use Noodle Browser?",
            message: "It can create browsers and use the ones you lend it.", caution: nil, items: [],
            decline: "Don’t Allow", accept: "Allow", finish: { _ in })
        let impostor = ExternalLauncher(key: "cdhash:ab", name: "Claude Code", path: "/tmp/Claude Code", identified: false)
        let warned = ExternalQuestion(icon: icon, title: "Allow “Claude Code” to use Noodle Browser?",
            message: "It can create browsers and use the ones you lend it.", caution: impostor.caution, items: [],
            decline: "Don’t Allow", accept: "Allow", finish: { _ in })
        let without = try render(plain, "question"), with = try render(warned, "question-caution")
        #expect(with.height > without.height + 20)
        #expect(with.width == without.width)
    }

    @Test func borrowingListsTheChoices() throws {
        let items = (1...3).map { ExternalItem(id: UUID(), name: "Browser \($0)", symbol: "globe") }
        let none = ExternalQuestion(icon: NSWorkspace.shared.icon(forFile: "/bin/zsh"), title: "“Claude Code” wants to borrow a browser",
            message: nil, caution: nil, items: [], decline: "Don’t Lend", accept: "Lend", finish: { _ in })
        let three = ExternalQuestion(icon: NSWorkspace.shared.icon(forFile: "/bin/zsh"), title: "“Claude Code” wants to borrow a browser",
            message: nil, caution: nil, items: items, decline: "Don’t Lend", accept: "Lend", finish: { _ in })
        #expect(try render(three, "borrow").height > render(none, "borrow-empty").height + 60)
    }

    @Test func settingsShowEachAppWithItsWarning() async throws {
        let answers = Yes(), gate = ExternalGate(url: nil, prompter: answers)
        gate.enabled = true
        let items = [ExternalItem(id: UUID(), name: "Research", symbol: "globe"), ExternalItem(id: UUID(), name: "Shopping", symbol: "cart")]
        let settings = { ExternalToolsSettingsView(gate: gate, noun: "browser", items: items,
            command: "/Applications/Noodle Browser.app/Contents/MacOS/noodle-browser", server: "noodle-browser", delete: { _ in })
            .frame(width: 580) }
        let empty = try render(settings(), "settings-empty")
        let claude = try await gate.admit(ExternalLauncher(key: "team:Q6L2SF6YDW:com.anthropic.claude-code", name: "Claude Code", path: "/c"))
        gate.recordCreated(items[0].id, by: claude.id)
        _ = try await gate.admit(ExternalLauncher(key: "path:/System/Applications/Utilities/Terminal.app", name: "Terminal",
                                                  path: "/System/Applications/Utilities/Terminal.app", broad: true))
        let full = try render(settings(), "settings")
        #expect(full.height > empty.height + 150)
    }

    /// Each app is one row however many items there are; its switches are in a sheet.
    @Test func manyItemsKeepEachAppToOneRow() async throws {
        let answers = Yes(), gate = ExternalGate(url: nil, prompter: answers)
        gate.enabled = true
        let few = (1...2).map { ExternalItem(id: UUID(), name: "Computer \($0)", symbol: "terminal") }
        let many = (1...12).map { ExternalItem(id: UUID(), name: "Computer \($0)", symbol: "terminal") }
        let claude = try await gate.admit(ExternalLauncher(key: "team:Q6L2SF6YDW:com.anthropic.claude-code", name: "Claude Code", path: "/c"))
        let settings = { (items: [ExternalItem]) in ExternalToolsSettingsView(gate: gate, noun: "computer", items: items,
            command: "/c", server: "noodle-computer", delete: { _ in }).frame(width: 580) }
        let short = try render(settings(few), "settings-few"), long = try render(settings(many), "settings-many")
        #expect(long.height == short.height)
        let sheet = { (items: [ExternalItem]) in ExternalCallerSheet(gate: gate, caller: claude, noun: "computer", items: items,
            remove: {}, done: {}) }
        #expect(try render(sheet(many), "caller-sheet").height > render(sheet(few), "caller-sheet-few").height + 200)
    }
}

@MainActor private final class Yes: ExternalPrompting {
    func approve(_ launcher: ExternalLauncher) async -> Bool { true }
    func pick(_ launcher: ExternalLauncher, from items: [ExternalItem]) async -> UUID? { items.first?.id }
    func confirm(_ launcher: ExternalLauncher, message: String, action: String) async -> Bool { true }
}
