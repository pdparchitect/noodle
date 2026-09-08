import AppKit
import SwiftUI
import NoodleCore

@MainActor final class KeyboardFixtureModel: ObservableObject {
    @Published var selection: Int? = 0
    @Published var focused = false
    @Published var text = ""
    @Published var search = ""
    @Published var searchFocused = false
    @Published var focusRequests = 0
    @Published var sidebarFocusRequest = UUID()
    let ids = [UUID(), UUID(), UUID()]
    let completion = ComposerNameCompletion()
}

struct KeyboardFixture: View {
    @ObservedObject var model: KeyboardFixtureModel
    var body: some View {
        HStack {
            VStack {
                TextField("Search fixture", text: $model.search)
                List(selection: $model.selection) {
                    ForEach(0..<3) { row in Text("Conversation \(row)").tag(row) }
                }
                .listStyle(.sidebar)
                .modifier(ConversationListKeyboardNavigation(hasSelection: model.selection != nil,
                    searchIsFocused: model.searchFocused, focusComposer: {
                        model.focusRequests += 1
                        model.focused = true
                    }, focusRequest: model.sidebarFocusRequest))
            }.frame(width: 200)
            VStack {
                Button("A control Tab must skip") {}
                Spacer()
                ScrollableChatComposer(text: $model.text, isFocused: $model.focused,
                    conversationID: model.ids[model.selection ?? 0], placeholder: "Message fixture",
                    agents: [], preferredIDs: [], completion: model.completion, submit: {},
                    focusSidebar: { model.sidebarFocusRequest = UUID() })
            }.frame(width: 320)
        }.padding(20).frame(height: 300)
    }
}

@main enum ConversationKeyboardChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = KeyboardFixtureModel()
        let window = NSWindow(contentRect: NSRect(x: 80, y: 100, width: 560, height: 340),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: KeyboardFixture(model: model))
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { fatalError("Keyboard fixture timed out") }
        Task { @MainActor in
            func settle() async { try? await Task.sleep(for: .milliseconds(250)) }
            @MainActor func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
                if let match = view as? T { return match }
                return view.subviews.lazy.compactMap { find(type, in: $0) }.first
            }
            @MainActor func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) {
                let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters,
                    isARepeat: false, keyCode: code)!
                app.sendEvent(event)
            }
            await settle()
            let table = find(NSTableView.self, in: window.contentView!)!
            let composer = find(ComposerScrollView.self, in: window.contentView!)!
            model.focused = true
            await settle()
            precondition(window.firstResponder === composer.editor)
            // Force the same ordering as clicking a new row before SwiftUI has
            // received the deferred editor-resigned callback.
            window.makeFirstResponder(table)
            model.selection = 1
            await settle()
            precondition(window.firstResponder === table, "Chat updates must not steal sidebar focus")
            key(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125, modifiers: [.function, .numericPad])
            await settle()
            precondition(model.selection == 2, "Down must select the next conversation")
            precondition(window.firstResponder === table)
            key(String(UnicodeScalar(NSUpArrowFunctionKey)!), code: 126, modifiers: [.function, .numericPad])
            await settle()
            precondition(model.selection == 1, "Up must select the previous conversation")
            precondition(window.firstResponder === table)
            key("\t", code: 48)
            await settle()
            precondition(model.focusRequests == 1, "Sidebar Tab must request composer focus")
            precondition(window.firstResponder === composer.editor, "Tab must skip intermediate controls")
            key("x", code: 7)
            await settle()
            precondition(model.text == "x", "Typing after Tab must enter the chat draft")

            let previousSidebarRequest = model.sidebarFocusRequest
            key("\u{19}", code: 48, modifiers: .shift)
            await settle()
            precondition(model.sidebarFocusRequest != previousSidebarRequest, "Shift-Tab must invoke the sidebar callback")
            precondition(window.firstResponder === table, "Composer Shift-Tab must return directly to the sidebar")
            precondition(model.selection == 1, "Returning focus must preserve the selected conversation")
            precondition(model.text == "x", "Shift-Tab must not modify the draft")
            key(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: 125, modifiers: [.function, .numericPad])
            await settle()
            precondition(model.selection == 2, "Arrow navigation must resume from the selected sidebar row")
            key("\t", code: 48)
            await settle()
            precondition(window.firstResponder === composer.editor, "Tab must work again after returning to the sidebar")

            key("\u{19}", code: 48, modifiers: .shift)
            await settle()
            precondition(window.firstResponder === table, "Repeated Shift-Tab must return to the sidebar")
            precondition(model.selection == 2)
            key("\u{19}", code: 48, modifiers: .shift)
            await settle()
            precondition(model.focusRequests == 2, "Sidebar Shift-Tab retains native navigation")
            window.makeFirstResponder(table)
            model.searchFocused = true
            await settle()
            key("\t", code: 48)
            await settle()
            precondition(model.focusRequests == 2, "Search must not use the sidebar shortcut")
            model.completion.detach()
            window.orderOut(nil)
            print("Conversation keyboard checks passed: stable sidebar focus, Up/Down, Tab/Shift-Tab round trip, typing and modified/search exclusions")
            exit(0)
        }
        app.run()
    }
}
