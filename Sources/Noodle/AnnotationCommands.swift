import SwiftUI
import Observation

@MainActor protocol PreviewAnnotationTarget: AnyObject {
    func annotate()
    func startRegion()
}

@MainActor @Observable final class AnnotationCommandsState {
    static let shared = AnnotationCommandsState()
    var enabled = false
    weak var owner: (any PreviewAnnotationTarget)?
    weak var conversationOwner: (any PreviewAnnotationTarget)?
    var conversationEnabled = false

    var target: (any PreviewAnnotationTarget)? { enabled ? owner : conversationEnabled ? conversationOwner : nil }
}

struct AnnotationCommands: Commands {
    private let state = AnnotationCommandsState.shared
    var body: some Commands {
        CommandMenu("Preview") {
            Button("Add Annotation…") { state.target?.annotate() }
                .appShortcut(.annotateSelection)
                .disabled(!state.enabled && !state.conversationEnabled)
            Button("Annotate Region…") { state.target?.startRegion() }
                .appShortcut(.annotateRegion)
                .disabled(!state.enabled && !state.conversationEnabled)
        }
    }
}
