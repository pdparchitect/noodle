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
        let picker = host(GroupMemberPicker(agents: f.store.agents, selectedIDs: selection.idsBinding))
        let addAll = try await control("Add Bots", in: picker)
        XCTAssertFalse(enabled(addAll))
        press(try await control("Remove Ada from group", in: picker))
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
        press(try await control("Remove Ada from group", in: editor))
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
        press(try await control("Remove Ada from group", in: editor))
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
        press(try await control("Remove Grace from group", in: editor))
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
        press(try await control("Remove Ada from group", in: editor))
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
        press(try await control("Remove Ada from group", in: editor))
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

    func testNewGroupSavesSeededMemberSelectionAndNormalizedName() async throws {
        let f = try fixture(); f.store.creationSheet = .group
        let editor = host(NewGroupSheet(participantIDs: [f.a.id, f.b.id]).environment(f.store))
        edit(try await textField("Group name", in: editor), text: "  New team  ")
        press(try await control("Create", in: editor))
        try await wait { f.store.creationSheet == nil }
        let group = try XCTUnwrap(f.store.selectedConversation)
        XCTAssertEqual(group.displayName, "New team")
        XCTAssertEqual(Set(group.participantIDs), [f.a.id, f.b.id])
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
}
