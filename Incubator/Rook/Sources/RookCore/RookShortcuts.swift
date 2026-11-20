import NoodleCore

/// Rook's keyboard shortcuts, each changeable in Settings > Keybindings. Those it shares with Noodle keep
/// Noodle's names, so the capture, call and annotation code both apps use finds them.
public enum RookShortcuts {
    public static let newMission = ShortcutDefinition(
        id: "newMission", title: "New Mission", summary: "Open a mission with a team of agents.",
        defaultBinding: KeyBinding("n"))
    public static let newGroup = ShortcutDefinition(
        id: ShortcutDefinition.newGroup.id, title: "New Group", summary: "Create a group conversation.",
        defaultBinding: KeyBinding("n", modifiers: [.command, .option]))
    public static let newAgent = ShortcutDefinition(
        id: "newAgent", title: "New Agent", summary: "Create an agent.",
        defaultBinding: KeyBinding("n", modifiers: [.command, .shift]))
    public static let searchConversations = ShortcutDefinition(
        id: ShortcutDefinition.searchConversations.id, title: "Search Conversations", summary: "Focus the conversation search field.",
        defaultBinding: KeyBinding("f"))
    public static let capture = ShortcutDefinition(
        id: ShortcutDefinition.capture.id, title: "Capture", summary: "Open the window picker or focus the existing capture preview.",
        defaultBinding: KeyBinding("s", modifiers: [.command, .shift]))
    public static let recordVoice = ShortcutDefinition(
        id: ShortcutDefinition.recordVoice.id, title: "Record / Stop Voice Message", summary: "Start or stop recording in the current chat.",
        defaultBinding: KeyBinding("d", modifiers: [.command, .shift]))
    public static let call = ShortcutDefinition(
        id: ShortcutDefinition.call.id, title: "Call / End Call", summary: "Call the agent in the current chat, or end the call in progress.",
        defaultBinding: KeyBinding("c", modifiers: [.command, .shift]))
    public static let stop = ShortcutDefinition(
        id: ShortcutDefinition.stopBot.id, title: "Stop Agent", summary: "End the turn the agent in the current chat is working on.",
        defaultBinding: KeyBinding("."))
    public static let usage = ShortcutDefinition(
        id: ShortcutDefinition.showUsage.id, title: "Usage", summary: "Show token usage, cost and storage for every agent.",
        defaultBinding: KeyBinding("u", modifiers: [.command, .shift]))
    public static let showInspector = ShortcutDefinition(
        id: "showInspector", title: "Show / Hide Inspector", summary: "Show or hide a mission's case record and audit log.",
        defaultBinding: KeyBinding("i", modifiers: [.command, .option]))
    public static let closeMission = ShortcutDefinition(
        id: "closeMission", title: "Close Mission", summary: "Close the current mission with its outcome.",
        defaultBinding: KeyBinding("k", modifiers: [.command, .shift]))
    public static let annotateSelection = ShortcutDefinition(
        id: ShortcutDefinition.annotateSelection.id, title: "Add Annotation",
        summary: "Comment on selected conversation or preview text; select a region for images.",
        defaultBinding: KeyBinding("a", modifiers: [.command, .shift]))
    public static let annotateRegion = ShortcutDefinition(
        id: ShortcutDefinition.annotateRegion.id, title: "Annotate Region",
        summary: "Mark a region of the Rook window, an attachment preview, or a live capture.",
        defaultBinding: KeyBinding("r", modifiers: [.command, .shift]))
    public static let saveAnnotation = ShortcutDefinition(
        id: ShortcutDefinition.saveAnnotation.id, title: "Save Annotation Comment", summary: "Save a new annotation or an unsent comment edit.",
        defaultBinding: KeyBinding("\r"))

    public static let catalog = [newMission, newGroup, newAgent, searchConversations, capture, recordVoice, call, stop,
                                 usage, showInspector, closeMission, annotateSelection, annotateRegion, saveAnnotation]
}
