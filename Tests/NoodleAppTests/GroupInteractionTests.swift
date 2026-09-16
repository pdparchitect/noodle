import AppKit
import SwiftUI
import Observation
import XCTest
import NoodleCore
@testable import Noodle

@MainActor @Observable final class MemberSelection {
    var ids = Set<UUID>()
    var search = ""
    var done = 0
    var idsBinding: Binding<Set<UUID>> { Binding(get: { self.ids }, set: { self.ids = $0 }) }
    var searchBinding: Binding<String> { Binding(get: { self.search }, set: { self.search = $0 }) }
}

@MainActor final class GroupInteractionTests: HiddenViewTests {
    func testSearchAddRemoveAndRepeatedAddKeepMembershipUnique() async throws {
        let f = try fixture(), selection = MemberSelection()
        let chooser = host(GroupMemberChooser(agents: f.store.agents, selectedIDs: selection.idsBinding,
            search: selection.searchBinding, onDone: { selection.done += 1 }))
        let search = try await textField("Search bots", in: chooser)
        edit(search, text: "GRACE")
        let add = try await control("Add Grace to group", in: chooser)
        try await wait { !self.hasControl("Add Ada to group", in: chooser) }
        press(add); press(add)
        try await wait { selection.ids == [f.b.id] }
        _ = try await control("No matching bots", in: chooser)
        edit(search, text: "")
        press(try await control("Add Ada to group", in: chooser))
        try await wait { selection.ids == [f.a.id, f.b.id] }
        _ = try await control("All bots added", in: chooser)
        press(try await control("Done", in: chooser)); XCTAssertEqual(selection.done, 1)
        let picker = host(GroupMemberPicker(agents: f.store.agents, selectedIDs: selection.idsBinding).environment(f.store))
        let addAll = try await control("Add Bots", in: picker)
        XCTAssertFalse(enabled(addAll))
        let confirmation = try await requestRemoval("Ada", in: picker)
        XCTAssertEqual(selection.ids, [f.a.id, f.b.id])
        XCTAssertFalse(hasControl("Direct Message", in: confirmation))
        press(try await control("Cancel", in: confirmation))
        try await wait { picker.window?.sheets.isEmpty == true }
        XCTAssertEqual(selection.ids, [f.a.id, f.b.id])
        try await removeMember("Ada", in: picker)
        try await wait { selection.ids == [f.b.id] }
        XCTAssertEqual(f.store.conversations.filter { $0.kind == .group }.count, 0)
    }

    func testNoBotsDisablesBothAddControls() async throws {
        let selection = MemberSelection()
        let picker = host(GroupMemberPicker(agents: [], selectedIDs: selection.idsBinding))
        let toolbar = try await control("Add Bots", in: picker)
        let empty = try await control("Add bots to this group", in: picker)
        XCTAssertFalse(enabled(toolbar)); XCTAssertFalse(enabled(empty))
        XCTAssertTrue(selection.ids.isEmpty)
    }

    func testGroupEditorSavesNameAndMembersToTheOriginalConversation() async throws {
        let f = try fixture(), group = try f.group()
        f.store.groupBeingEdited = group
        let editor = host(GroupInfoSheet(conversation: group).environment(f.store))
        edit(try await nameField(in: editor, name: group.displayName), text: " Renamed group ")
        try await removeMember("Ada", in: editor)
        press(try await control("Save", in: editor))
        try await wait { f.store.groupBeingEdited == nil }
        let saved = try XCTUnwrap(f.repository.loadConversations().first { $0.id == group.id })
        XCTAssertEqual(saved.displayName, "Renamed group"); XCTAssertEqual(saved.participantIDs, [f.b.id])
        XCTAssertEqual(f.store.conversations.filter { $0.kind == .group }.count, 1)
        XCTAssertEqual(try f.repository.loadMessages(conversationID: group.id).filter { $0.author == .system }.count, 1)
    }

    func testGroupEditorCannotSaveUnchangedWhitespaceBlankNameOrNoMembers() async throws {
        let f = try fixture(), group = try f.group([f.a.id])
        let editor = host(GroupInfoSheet(conversation: group).environment(f.store))
        let field = try await nameField(in: editor, name: group.displayName)
        for name in [group.displayName, " \(group.displayName) ", "  "] {
            edit(field, text: name)
            let save = try await control("Save", in: editor)
            try await wait { !self.enabled(save) }
        }
        edit(field, text: "Changed")
        try await removeMember("Ada", in: editor)
        let save = try await control("Save", in: editor)
        try await wait { !self.enabled(save) }
        XCTAssertEqual(try f.repository.loadConversations().first { $0.id == group.id }?.participantIDs, [f.a.id])
    }

    func testCancellingGroupEditsDoesNotPersistNameOrMembers() async throws {
        let f = try fixture(), group = try f.group()
        let file = f.repository.conversationDirectory(id: group.id).appendingPathComponent("conversation.json")
        let before = try Data(contentsOf: file)
        let editor = host(GroupInfoSheet(conversation: group).environment(f.store))
        edit(try await nameField(in: editor, name: group.displayName), text: "Cancelled")
        try await removeMember("Grace", in: editor)
        press(try await control("Cancel", in: editor))
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertTrue(try f.repository.loadMessages(conversationID: group.id).isEmpty)
    }

    func testFailedMetadataSaveRetainsDraftAndRetrySavesOnce() async throws {
        let f = try fixture(), group = try f.group()
        f.store.groupBeingEdited = group
        let file = f.repository.conversationDirectory(id: group.id).appendingPathComponent("conversation.json")
        let original = try Data(contentsOf: file)
        let editor = host(GroupInfoSheet(conversation: group).environment(f.store))
        let field = try await nameField(in: editor, name: group.displayName)
        edit(field, text: "Retried group")
        try await removeMember("Ada", in: editor)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        press(try await control("Save", in: editor))
        try await wait { f.store.errorMessage != nil }
        XCTAssertEqual(field.stringValue, "Retried group")
        XCTAssertEqual(f.store.groupBeingEdited?.id, group.id)
        XCTAssertEqual(f.store.conversations.first { $0.id == group.id }?.displayName, group.displayName)
        try FileManager.default.removeItem(at: file); try original.write(to: file)
        press(try await control("Save", in: editor))
        try await wait { f.store.groupBeingEdited == nil }
        XCTAssertEqual(try f.repository.loadConversations().first { $0.id == group.id }?.participantIDs, [f.b.id])
        XCTAssertEqual(try f.repository.loadMessages(conversationID: group.id).count, 1)
    }

    func testFailedNoticeSaveDoesNotPublishMembershipAndRetryStillCreatesNotice() async throws {
        let f = try fixture(), group = try f.group()
        let folder = f.repository.conversationDirectory(id: group.id)
        let metadata = folder.appendingPathComponent("conversation.json"), messages = folder.appendingPathComponent("messages.json")
        let original = try Data(contentsOf: metadata), history = try Data(contentsOf: messages)
        let editor = host(GroupInfoSheet(conversation: group).environment(f.store))
        try await removeMember("Ada", in: editor)
        try FileManager.default.removeItem(at: messages)
        try FileManager.default.createDirectory(at: messages, withIntermediateDirectories: false)
        press(try await control("Save", in: editor))
        try await wait { f.store.errorMessage != nil }
        XCTAssertEqual(try Data(contentsOf: metadata), original)
        XCTAssertEqual(Set(f.store.conversations.first { $0.id == group.id }!.participantIDs), [f.a.id, f.b.id])
        try FileManager.default.removeItem(at: messages); try history.write(to: messages)
        press(try await control("Save", in: editor))
        try await wait { f.store.conversations.first { $0.id == group.id }?.participantIDs == [f.b.id] }
        XCTAssertEqual(try f.repository.loadMessages(conversationID: group.id).count, 1)
    }

    func testNewGroupSavesConfirmedMemberSelectionAndNormalizedName() async throws {
        let f = try fixture(); f.store.creationSheet = .group
        let editor = host(NewGroupSheet(participantIDs: [f.a.id, f.b.id]).environment(f.store))
        edit(try await textField("Group name", in: editor), text: "  New team  ")
        try await removeMember("Grace", in: editor)
        press(try await control("Create", in: editor))
        try await wait { f.store.creationSheet == nil }
        let group = try XCTUnwrap(f.store.selectedConversation)
        XCTAssertEqual(group.displayName, "New team")
        XCTAssertEqual(Set(group.participantIDs), [f.a.id])
        XCTAssertEqual(try f.repository.loadConversations().filter { $0.kind == .group }.count, 1)
        XCTAssertTrue(f.runtime.factory.processes.isEmpty)
    }

    func testNewGroupCannotCreateWithoutNameOrMembersAndCancelPreservesChats() async throws {
        let f = try fixture()
        let editor = host(NewGroupSheet().environment(f.store))
        let empty = try await control("Create", in: editor)
        XCTAssertFalse(enabled(empty))
        edit(try await textField("Group name", in: editor), text: "No members")
        let unnamed = try await control("Create", in: editor)
        XCTAssertFalse(enabled(unnamed))
        press(try await control("Cancel", in: editor))
        XCTAssertEqual(try f.repository.loadConversations().count, 2)
    }

    func testMemberProfilesAndNestedBotEditsPreserveNewAndExistingGroupDrafts() async throws {
        for isExisting in [false, true] {
            let f = try fixture()
            let group = isExisting ? try f.group() : nil
            let parent = host(Color.clear.sheet(isPresented: .constant(true)) {
                if let group { GroupInfoSheet(conversation: group).environment(f.store) }
                else { NewGroupSheet(participantIDs: [f.a.id, f.b.id]).environment(f.store) }
            })
            let parentWindow = try XCTUnwrap(parent.window)
            parentWindow.orderFront(nil)
            try await wait { !parentWindow.sheets.isEmpty }
            let groupWindow = try XCTUnwrap(parentWindow.sheets.first)
            let editor = try XCTUnwrap(groupWindow.contentView)
            let name = try await textField("Group name", in: editor)
            edit(name, text: "Pending group name")

            press(try await control("Show profile for Ada", in: editor))
            var profile: NSView?
            try await wait {
                profile = NSApp.windows.filter { $0.isVisible && $0.sheetParent == nil }
                    .compactMap(\.contentView).first { self.hasControl("Close bot profile", in: $0) }
                return profile != nil
            }
            let content = try XCTUnwrap(profile)
            _ = try await control("Ada", in: content)
            let message = try await control("Direct Message", in: content)
            XCTAssertTrue(enabled(message))
            XCTAssertTrue(hasControl("Remove Ada from group", in: editor))
            press(try await control("Edit Bot", in: content))
            try await wait { !groupWindow.sheets.isEmpty }
            let botEditor = try XCTUnwrap(groupWindow.sheets.first?.contentView)
            edit(try await nameField(in: botEditor, name: "Ada"), text: "Ada Updated")
            press(try await control("Save", in: botEditor))
            try await wait { groupWindow.sheets.isEmpty }
            _ = try await control("Show profile for Ada Updated", in: editor)
            XCTAssertEqual(name.stringValue, "Pending group name")
            XCTAssertTrue(hasControl("Remove Ada Updated from group", in: editor))
            XCTAssertTrue(hasControl("Remove Grace from group", in: editor))
            let groups = try f.repository.loadConversations().filter { $0.kind == .group }
            XCTAssertEqual(groups.count, isExisting ? 1 : 0)
            if let group {
                XCTAssertEqual(groups.first?.displayName, group.displayName)
                XCTAssertEqual(Set(groups.first!.participantIDs), [f.a.id, f.b.id])
            }
            parentWindow.endSheet(groupWindow)
            groupWindow.orderOut(nil)
            parentWindow.close()
        }
    }

    private func requestRemoval(_ name: String, in editor: NSView) async throws -> NSView {
        let window = try XCTUnwrap(editor.window)
        window.orderFront(nil)
        press(try await control("Remove \(name) from group", in: editor))
        try await wait { !window.sheets.isEmpty }
        let confirmation = try XCTUnwrap(window.sheets.first?.contentView)
        _ = try await control("Remove \(name) from group?", in: confirmation)
        return confirmation
    }

    private func removeMember(_ name: String, in editor: NSView) async throws {
        let confirmation = try await requestRemoval(name, in: editor)
        press(try await control("Remove from Group", in: confirmation))
        try await wait { editor.window?.sheets.isEmpty == true }
    }

}
