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
}
