import Foundation
import NoodleCore

/// The enclosing editor owns imported media until Save or Cancel.
struct ConversationBackgroundDraft: Equatable {
    var background: ConversationBackground
    var imageData: Data?
    var file: PreparedBackgroundFile?
}

