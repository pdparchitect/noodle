import Foundation

/// An update may be downloaded at any time, but restarting must not discard work.
public enum UpdateReadiness {
    public static func canRelaunch(
        phases: [AgentRuntimePhase],
        draft: String,
        hasAttachments: Bool,
        isEditing: Bool
    ) -> Bool {
        !phases.contains(where: { $0 == .starting || $0 == .working })
            && draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !hasAttachments
            && !isEditing
    }
}
