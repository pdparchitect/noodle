import Foundation

/// Fixed native arguments shared by the signed host and executable smoke tests.
public enum ClaudeLaunch {
    public static func arguments(sessionID: UUID?, resumeSession: Bool, model: String?,
                                 effort: String?, restricted: Bool) throws -> [String] {
        guard let sessionID else { throw HarnessSetupError("Claude Code requires a valid session identifier.") }
        guard model.map(ClaudeCodeCapabilities.isValidModelIdentifier) ?? true else {
            throw HarnessSetupError("Unsupported Claude Code model identifier.")
        }
        guard effort.map({ ["low", "medium", "high", "xhigh", "max"].contains($0) }) ?? true else {
            throw HarnessSetupError("Unsupported Claude Code effort.")
        }
        var arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json",
            "--verbose", "--permission-mode", "bypassPermissions", "--permission-prompts", "none",
            resumeSession ? "--resume" : "--session-id", sessionID.uuidString.lowercased()]
        if let model { arguments += ["--model", model] }
        if let effort { arguments += ["--effort", effort] }
        // The host applies Seatbelt to the entire process tree. Claude's nested
        // Bash sandbox cannot be stacked inside it; keep the normal tool set.
        if restricted { arguments += ["--settings", #"{"sandbox":{"enabled":false}}"#] }
        return arguments
    }
}
