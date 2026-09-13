import Foundation

/// App-startup-only migration from workspace Markdown to private configuration.
/// A present backstory field, including an empty string, is the completion flag.
// TODO(0.15.0): Remove this migrator and its startup call only after verifying
// upgrades pass through the published 0.14.0 milestone. Keep requireBackstory(),
// the 0.14.0 update milestone, and manual-upgrade guidance for older packages.
enum AgentBackstoryMigration {
    @discardableResult
    static func migrate(_ layout: AgentStorageLayout) throws -> Bool {
        try layout.validate()
        var configuration = try AgentConfiguration.load(from: layout)
        guard configuration.backstory == nil else { return false }
        let files = try WorkspaceMailbox(workspace: layout.workspace, path: "")
        configuration.backstory = try legacyBackstory(in: files)
        // Commit the source of truth before any workspace regeneration. A crash
        // before this atomic write leaves the legacy files intact; after it, the
        // next run skips parsing and can safely regenerate or repair AGENTS.md.
        try configuration.save(to: layout)
        return true
    }

    private static func legacyBackstory(in files: WorkspaceMailbox) throws -> String {
        if files.contains("AGENTS.md") {
            let contents = try text("AGENTS.md", in: files)
            let lines = contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            let start = lines.filter { $0 == "<!-- noodle:managed:start -->" }
            let end = lines.filter { $0 == "<!-- noodle:managed:end -->" }
            if let heading = lines.first(where: { $0 == "## Backstory" }), start.count == 1, end.count == 1,
               heading.endIndex < start[0].startIndex, start[0].endIndex < end[0].startIndex {
                return String(contents[heading.endIndex..<start[0].startIndex])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let generated = contents.contains("# Noodle Agent") || contents.contains("noodle:managed:")
            if !generated, !contents.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return normalized(contents)
            }
            // The earliest generated guide had no Backstory section; its
            // separate instructions.md remained the user-authored source.
            if generated, !contents.contains("## Backstory"), !contents.contains("noodle:managed:"),
               contents.contains("## Messages"), contents.contains("--get-latest"), files.contains("instructions.md") {
                return normalized(try text("instructions.md", in: files))
            }
            throw damagedBackstory()
        }
        guard files.contains("instructions.md") else { throw damagedBackstory() }
        return normalized(try text("instructions.md", in: files))
    }

    private static func text(_ name: String, in files: WorkspaceMailbox) throws -> String {
        guard let contents = String(data: try files.read(name, limit: 4 * 1_048_576), encoding: .utf8) else {
            throw damagedBackstory()
        }
        return contents
    }

    private static func normalized(_ contents: String) -> String {
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = trimmed.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).first,
           first.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("# Instructions") == .orderedSame {
            return String(trimmed[first.endIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    private static func damagedBackstory() -> AgentStorageError {
        AgentStorageError("This bot's legacy backstory is missing or its generated instruction markers are damaged. Its files have been left unchanged. Restore the original AGENTS.md or instructions.md before retrying the migration.")
    }
}
