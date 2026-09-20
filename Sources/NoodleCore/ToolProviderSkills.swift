import Foundation

/// One generated skill per active provider, so bots find tools the way they find
/// every other skill. The text comes from the provider's manifest and tool list.
public enum ToolProviderSkills {
    /// Distinguishes these folders from other Noodle-managed skills when cleaning up.
    static let marker = ".noodle-tool-provider"

    public static func document(_ manifest: ToolProviderManifest, tools: [ToolDescriptor]) -> String {
        let line: (String) -> String = { $0.split(whereSeparator: \.isNewline).joined(separator: " ") }
        let command = "./.agents/skills/messenger/messenger tool \(manifest.id)"
        // A JSON string is a valid YAML scalar, so quotes and colons in a name cannot break the header.
        let summary = line(manifest.summary) + (manifest.summary.isEmpty ? "" : " ") + "Tools: \(tools.map(\.name).joined(separator: ", "))."
        let description = String(data: (try? JSONEncoder().encode(String(summary.prefix(1024)))) ?? Data("\"\"".utf8), encoding: .utf8) ?? "\"\""
        var text = """
        ---
        name: \(manifest.id)
        description: \(description)
        ---
        # \(line(manifest.title))

        Run `\(command) TOOL [--OPTION VALUE ...]` in this bot's workspace. Noodle must be running. `\(command)` lists the tools and `\(command) TOOL --help` returns one tool's full schema. Use `--input JSON` for values options cannot express. File options take a path inside your workspace. Results are JSON; a tool error exits 1. Never automatically repeat a call that timed out: the action may already have happened. To chain this with other tools in one script, see `tool --run` in the Messenger skill.
        """
        if !manifest.instructions.isEmpty { text += "\n\n" + manifest.instructions }
        text += "\n\n## Tools\n"
        for tool in tools {
            text += "\n### \(tool.name)\n\n" + (tool.description.isEmpty ? "" : line(tool.description) + "\n\n")
            let schema = (try? JSONSerialization.jsonObject(with: tool.inputSchema)) as? [String: Any] ?? [:]
            let required = Set(schema["required"] as? [String] ?? [])
            for (name, value) in (schema["properties"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
                let property = value as? [String: Any] ?? [:]
                let type = property["type"] as? String
                let placeholder = type == "boolean" ? "" : property["format"] as? String == "noodle-file" ? " FILE" : " VALUE"
                let notes = [required.contains(name) ? "required" : nil, type == "array" ? "repeatable" : nil].compactMap { $0 }
                let description = (property["description"] as? String).map { " — " + line($0) } ?? ""
                text += "- `--\(name)\(placeholder)`\(notes.isEmpty ? "" : " (\(notes.joined(separator: ", ")))")\(description)\n"
            }
        }
        return text
    }

    /// The part of a skill that does not depend on its tool list: everything between the header and "## Tools".
    private static func guidance(_ document: String) -> Substring {
        let body = document.range(of: "\n---\n").map { document[$0.upperBound...] } ?? document[...]
        return body.range(of: "\n## Tools\n").map { body[..<$0.lowerBound] } ?? body
    }

    /// The skills Noodle generated in this workspace, with the one-line description from each.
    public static func generated(workspace: URL) -> [(name: String, description: String)] {
        guard let skills = try? WorkspaceMailbox(workspace: workspace, path: ".agents/skills"), let names = try? skills.names() else { return [] }
        return names.sorted().compactMap { name in
            guard let folder = try? WorkspaceMailbox(workspace: workspace, path: ".agents/skills/" + name), folder.contains(marker),
                  let text = try? String(decoding: folder.read("SKILL.md", limit: 1_048_576), as: UTF8.self) else { return nil }
            let line = text.split(separator: "\n").prefix(8).first { $0.hasPrefix("description: ") }.map { String($0.dropFirst(13)) } ?? ""
            return (name, (try? JSONDecoder().decode(String.self, from: Data(line.utf8))) ?? line)
        }
    }

    /// What a bot's AGENTS.md says about them. Noodle names no tool itself.
    public static func instructions(workspace: URL) -> String {
        let skills = generated(workspace: workspace)
        guard !skills.isEmpty else { return "" }
        return "\n## Tools\n\nNoodle provides these tools to you. Read a tool's skill before using it.\n\n"
            + skills.map { "- `.agents/skills/\($0.name)/SKILL.md`: \($0.description)" }.joined(separator: "\n") + "\n"
    }

    /// Writes a skill for every listed provider and removes generated skills that are
    /// no longer listed. A user's own skill of the same name is left exactly as it is.
    public static func synchronize(workspace: URL, providers: [(manifest: ToolProviderManifest, tools: [ToolDescriptor])]) {
        synchronize(workspace: workspace, listed: providers.map { ($0.manifest, Optional($0.tools)) })
    }

    /// `tools` is nil while a provider cannot list them. Its skill is then written without a
    /// tool list, or left as it was if one already exists, so a passing failure erases nothing.
    public static func synchronize(workspace: URL, listed providers: [(manifest: ToolProviderManifest, tools: [ToolDescriptor]?)]) {
        let active = Set(providers.map(\.manifest.id))
        if let skills = try? WorkspaceMailbox(workspace: workspace, path: ".agents/skills"), let names = try? skills.names() {
            for name in names where !active.contains(name) {
                guard let folder = try? WorkspaceMailbox(workspace: workspace, path: ".agents/skills/" + name), folder.contains(marker) else { continue }
                folder.remove(marker)
                try? WorkspaceMailbox.synchronizeSkill(workspace: workspace, name: name, enabled: false, instructions: "", command: marker, executable: nil)
            }
        }
        for provider in providers {
            let name = provider.manifest.id
            // While tools cannot be listed, keep the last good skill, unless its title or guidance
            // changed: a rename or new instructions must still reach the bot.
            if provider.tools == nil, let existing = try? WorkspaceMailbox(workspace: workspace, path: ".agents/skills/" + name),
               existing.contains(marker), let current = try? String(decoding: existing.read("SKILL.md", limit: 1_048_576), as: UTF8.self),
               guidance(current) == guidance(document(provider.manifest, tools: [])) { continue }
            do {
                try WorkspaceMailbox.synchronizeSkill(workspace: workspace, name: name, enabled: true,
                    instructions: document(provider.manifest, tools: provider.tools ?? []), command: marker, executable: nil)
                let folder = try WorkspaceMailbox(workspace: workspace, path: ".agents/skills/" + name)
                try folder.writeData(Data(), named: marker)
                // Workspaces whose .claude/skills is a real folder list each skill by link.
                if let native = try? WorkspaceMailbox(workspace: workspace, path: ".claude/skills"), !native.contains(name) {
                    try? native.symlink(name, destination: "../../.agents/skills/" + name)
                }
            } catch { NSLog("Noodle could not write the %@ tool skill: %@", name, error.localizedDescription) }
        }
    }
}
