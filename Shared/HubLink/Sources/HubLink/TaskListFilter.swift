/// Which of the bots' tasks the conversation list shows above the conversations, if any.
public enum TaskListFilter: String, CaseIterable, Identifiable, Sendable {
    case hidden, waitingOnMe, allOpen

    public static let key = "sidebarTasks"
    public static let standard = Self.hidden
    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .hidden: "Hidden"
        case .waitingOnMe: "Waiting on Me"
        case .allOpen: "All Open"
        }
    }

    /// As a menu item that switches to it.
    public var menuName: String {
        switch self {
        case .hidden: "Hide Tasks"
        case .waitingOnMe: "Show Tasks Waiting on Me"
        case .allOpen: "Show All Open Tasks"
        }
    }
}
