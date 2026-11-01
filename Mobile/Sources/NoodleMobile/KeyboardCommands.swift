import HubLink
import SwiftUI
import UIKit

/// What the keyboard's commands do on the home screen in front. Each is nil while it has nothing to do.
struct HomeCommands {
    var newBot: (() -> Void)?
    var newGroup: (() -> Void)?
    var search: (() -> Void)?
    var next: (() -> Void)?
    var previous: (() -> Void)?
    var close: (() -> Void)?
    var settings: (() -> Void)?
    var spaces: [SpaceCommand] = []
    var newSpace: (() -> Void)?
    var editSpaces: (() -> Void)?
}

/// A space in the Spaces menu, ticked while it is shown.
struct SpaceCommand: Identifiable {
    let id: String
    let title: String
    let isShown: Bool
    let show: () -> Void

    /// ⌘1 for the first, All, to ⌘9, as on the Mac; the rest have none.
    static func shortcut(at index: Int) -> KeyboardShortcut? {
        (0..<9).contains(index) ? KeyboardShortcut(KeyEquivalent(Character("\(index + 1)"))) : nil
    }
}

extension FocusedValues {
    @Entry var homeCommands: HomeCommands?
}

/// The app's menus, laid out as the Mac's where it has the same command: in the menu bar on a Mac and on iPad,
/// and listed by holding ⌘ with a hardware keyboard. Sections draw the separators; a divider shows none there.
struct NoodleCommands: Commands {
    @FocusedValue(\.homeCommands) private var home
    @AppStorage(ConversationRowDetail.key) private var rowDetail = ConversationRowDetail.standard.rawValue
    @AppStorage(ConversationOrder.key) private var conversationOrder = ConversationOrder.standard.rawValue
    @AppStorage(AttachmentLayout.key) private var attachmentLayout = AttachmentLayout.standard.rawValue
    @AppStorage(MessageTextLayout.key) private var textLayout = MessageTextLayout.standard.rawValue

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            command("Settings…", home?.settings).keyboardShortcut(",")
        }
        CommandGroup(replacing: .newItem) {
            command("New Bot", home?.newBot).keyboardShortcut("n")
            command("New Group", home?.newGroup).keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(before: .toolbar) {
            Section {
                Menu("Sidebar") {
                    Section { choices($rowDetail, ConversationRowDetail.allCases) { "Show \($0.name)" } }
                    Section { choices($conversationOrder, ConversationOrder.allCases) { $0.name } }
                }
                Menu("Conversation") {
                    Section("Attachments") { choices($attachmentLayout, AttachmentLayout.allCases) { $0.name } }
                    Section("Long Messages") { choices($textLayout, MessageTextLayout.allCases) { $0.name } }
                }
            }
        }
        CommandMenu("Conversation") {
            Section {
                command("Search Conversations", home?.search).keyboardShortcut("f")
            }
            Section {
                command("Next Conversation", home?.next).keyboardShortcut(.downArrow, modifiers: [.command, .option])
                command("Previous Conversation", home?.previous).keyboardShortcut(.upArrow, modifiers: [.command, .option])
                command("Close Conversation", home?.close).keyboardShortcut(.escape, modifiers: [])
            }
        }
        if let home, home.spaces.count > 1 || home.newSpace != nil {
            CommandMenu("Spaces") {
                Section {
                    ForEach(Array(home.spaces.enumerated()), id: \.element.id) { index, space in
                        Toggle(space.title, isOn: Binding(get: { space.isShown }, set: { if $0 { KeyboardCommand.run(space.show) } }))
                            .keyboardShortcut(SpaceCommand.shortcut(at: index))
                    }
                }
                Section {
                    command("New Space…", home.newSpace)
                    if home.editSpaces != nil { command("Edit Spaces…", home.editSpaces) }
                }
            }
        }
        CommandGroup(replacing: .help) {
            Button("Noodle Help") { UIApplication.shared.open(NoodleCommands.help) }
        }
    }

    static let help = URL(string: "https://github.com/pdparchitect/noodle")!

    /// A choice of stored values as checkmark items, as the Mac's View menu lists them. Toggles, not an inline
    /// picker, which brings its own separators and so a line between a section's heading and its items.
    private func choices<Choice: RawRepresentable & Identifiable>(_ selection: Binding<String>, _ all: [Choice],
                                                                  title: @escaping (Choice) -> String) -> some View
        where Choice.RawValue == String {
        ForEach(all) { choice in
            Toggle(title(choice), isOn: Binding(get: { selection.wrappedValue == choice.rawValue },
                                                set: { if $0 { selection.wrappedValue = choice.rawValue } }))
        }
    }

    private func command(_ title: String, _ action: (() -> Void)?) -> some View {
        Button(title) { if let action { KeyboardCommand.run(action) } }
            .disabled(action == nil)
    }
}

@MainActor enum KeyboardCommand {
    /// Runs a menu command unless a sheet or full-screen view is up, which the command would act behind.
    static func run(_ action: () -> Void) {
        if !isPresenting() { action() }
    }

    static func isPresenting(in windows: [UIWindow] = UIApplication.shared.connectedScenes
        .compactMap { ($0 as? UIWindowScene)?.keyWindow }) -> Bool {
        windows.contains { $0.rootViewController?.presentedViewController != nil }
    }
}

extension PastingTextView {
    /// With a hardware keyboard Return sends, as in Messages on iPad. Shift-Return has no command of its own, so
    /// the field starts a new line, as it does for the on-screen keyboard's return key, which is no key command.
    static var sendCommand: UIKeyCommand {
        let command = UIKeyCommand(title: "Send", action: #selector(PastingTextView.sendFromKeyboard), input: "\r", modifierFlags: [])
        command.wantsPriorityOverSystemBehavior = true
        return command
    }
}
