import AppKit
import BrowserBridge
import ComputerBridge
import NoodleCore
import SwiftUI
import XCTest
@testable import Noodle

@MainActor final class CompanionAssignmentPickerTests: HiddenViewTests {
    func testSearchAddRemoveAndUnavailableAssignmentsStayInTheDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root); try repository.prepare()
        let agent = try repository.createAgent(named: "Fixture").agent
        let work = RemoteBrowser(id: UUID(), name: "Work"), personal = RemoteBrowser(id: UUID(), name: "Personal", colour: 1)
        let controller = BrowserController(repository: repository, connection: { _ in
            var response = BrowserResponse(); response.browsers = [work, personal]; return response
        })
        await controller.refresh(); try controller.assign([work.id], to: agent, synchronizeWorkspace: false)
        let before = try Data(contentsOf: root.appendingPathComponent("browsers.json"))
        let selection = MemberSelection(); selection.ids = [work.id]
        let items = [work, personal].map { CompanionAssignmentItem(id: $0.id, name: $0.name, state: "Ready", symbol: $0.symbol, colour: $0.colour) }
        let chooser = host(CompanionAssignmentChooser(title: "Browsers", items: items, selectedIDs: selection.idsBinding,
            search: selection.searchBinding, createPrompt: Text("No browsers"), openLibraryButton: Button("Open Noodle Browser") {},
            onDone: { selection.done += 1 }))
        let search = try await textField("Search browsers", in: chooser)
        edit(search, text: "nobody")
        _ = try await control("No matching browsers", in: chooser)
        edit(search, text: "PERSON")
        let add = try await control("Add Personal to bot", in: chooser)
        press(add); press(add)
        try await wait { selection.ids == [work.id, personal.id] }
        press(try await control("Done", in: chooser)); XCTAssertEqual(selection.done, 1)
        let missing = UUID(); selection.ids.insert(missing)
        let picker = host(BrowserAssignmentPicker(controller: controller, selectedIDs: selection.idsBinding))
        _ = try await control("Add Browsers", in: picker)
        let window = try XCTUnwrap(picker.window)
        func confirmation(_ name: String) async throws -> NSView {
            press(try await control("Remove \(name) from bot", in: picker))
            try await wait { !window.sheets.isEmpty }
            let content = try XCTUnwrap(window.sheets.first?.contentView)
            _ = try await control("Remove “\(name)”?", in: content)
            return content
        }
        press(try await control("Cancel", in: try await confirmation("Work")))
        try await wait { window.sheets.isEmpty }
        XCTAssertEqual(selection.ids, [work.id, personal.id, missing], "Cancel must keep the browser")
        press(try await control("Remove Browser", in: try await confirmation("Work")))
        try await wait { window.sheets.isEmpty && !selection.ids.contains(work.id) }
        press(try await control("Remove Browser", in: try await confirmation("Unavailable browser")))
        try await wait { selection.ids == [personal.id] }
        XCTAssertEqual(controller.selectedIDs(for: agent), [work.id])
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("browsers.json")), before)
    }

    func testBrowserAndComputerAssignmentPreviews() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = WorkspaceRepository(rootURL: root); try repository.prepare()
        let browser = RemoteBrowser(id: UUID(), name: "Browser")
        let computer = RemoteComputer(id: UUID(), name: "My Local Mac", kind: "Mac", state: "Running", symbol: "person.crop.square", colour: 0)
        let browsers = BrowserController(repository: repository, connection: { _ in
            var response = BrowserResponse(); response.browsers = [browser]; return response
        })
        let computers = ComputerController(repository: repository, applicationLookup: { nil }, connection: { _ in
            var response = ComputerResponse(computers: [computer]); response.capabilities = ComputerCapabilities(); return response
        })
        await browsers.refresh(); await computers.refresh()
        let preview = host(VStack(alignment: .leading, spacing: 24) {
            BrowserAssignmentPicker(controller: browsers, selectedIDs: .constant([browser.id]))
            ComputerAssignmentPicker(controller: computers, selectedIDs: .constant([computer.id]))
        }.padding(20).frame(width: 520).preferredColorScheme(.dark))
        preview.window?.setContentSize(.init(width: 520, height: 460))
        _ = try await control("Remove Browser from bot", in: preview)
        _ = try await control("Remove My Local Mac from bot", in: preview)
        preview.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(preview.bitmapImageRepForCachingDisplay(in: preview.bounds))
        preview.effectiveAppearance.performAsCurrentDrawingAppearance { preview.cacheDisplay(in: preview.bounds, to: bitmap) }
        let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let output = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/browser-assignment-preview.png")
        try image.write(to: output)
        print("BROWSER_ASSIGNMENT_PREVIEW: \(output.path)")
    }
}
