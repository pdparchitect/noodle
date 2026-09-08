import SwiftUI

/// Only the conversation list shortcuts forward Tab; text fields, menus and
/// modified keys keep their native handling.
struct ConversationListKeyboardNavigation: ViewModifier {
    let hasSelection: Bool
    let searchIsFocused: Bool
    let focusComposer: () -> Void

    func body(content: Content) -> some View {
        content.onKeyPress(.tab, phases: .down) { press in
            guard hasSelection, !searchIsFocused,
                  press.modifiers.intersection([.shift, .option, .control, .command]).isEmpty else { return .ignored }
            focusComposer()
            return .handled
        }
    }
}
