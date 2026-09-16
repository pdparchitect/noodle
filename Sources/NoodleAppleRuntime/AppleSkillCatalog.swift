import Darwin
import Foundation
import NoodleCore

/// Skill metadata is always available to the model; bodies are read on demand.
/// Discover the workspace's skills, including user skills, without a managed
/// marker or a built-in list of integrations.
enum AppleSkillCatalog {
    struct Skill: Equatable {
        let name: String
        let description: String
        let path: String
    }

    static func load(workspace: URL) throws -> [Skill] {
        let directory = workspace.appendingPathComponent(".agents/skills")
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            return []
        } catch {
            throw HarnessSetupError("Could not discover workspace skills: \(error.localizedDescription)")
        }
        var seen = Set<String>()
        return entries.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { entry in
            let file = entry.appendingPathComponent("SKILL.md")
            guard let contents = readHeader(file), seen.insert(file.resolvingSymlinksInPath().path).inserted else { return nil }
            return parse(contents, directory: entry.lastPathComponent,
                         path: ".agents/skills/\(entry.lastPathComponent)/SKILL.md")
        }
    }

    static func text(workspace: URL) throws -> String {
        let skills = try load(workspace: workspace)
        guard !skills.isEmpty else { return "" }
        return "\n\n<available_skills>\nRead the relevant skill's SKILL.md with the read tool, then follow its instructions.\n"
            + skills.map { skill in
                "<skill>\n<name>\(escape(skill.name))</name>\n<description>\(escape(skill.description))</description>\n<path>\(escape(skill.path))</path>\n</skill>"
            }.joined(separator: "\n") + "\n</available_skills>"
    }

    private static func readHeader(_ file: URL) -> String? {
        // Use the helper's existing filesystem permissions, including for
        // linked skills. A broken skill or non-regular file cannot block chat.
        let descriptor = Darwin.open(file.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              let data = try? handle.read(upToCount: 65_536) else { return nil }
        // A page can end inside a UTF-8 character in the unused body without
        // invalidating the metadata at the beginning of the file.
        return String(decoding: data, as: UTF8.self)
    }

    static func parse(_ contents: String, directory: String, path: String) -> Skill? {
        let lines = contents.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}"))
            .components(separatedBy: "\n")
        var fields: [String: String] = [:]
        var bodyStart = 0
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            guard let end = lines.indices.dropFirst().first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "---" }) else {
                return nil
            }
            bodyStart = end + 1
            var index = 1
            while index < end {
                let line = lines[index]
                index += 1
                // Only top-level metadata, never similarly named nested keys.
                guard line.first?.isWhitespace == false, let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                guard key == "name" || key == "description" else { continue }
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                var continuations: [String] = []
                while index < end && (lines[index].isEmpty || lines[index].first?.isWhitespace == true) {
                    continuations.append(lines[index].trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                if [">", ">-", ">+", "|", "|-", "|+"].contains(value) {
                    fields[key] = continuations.joined(separator: value.hasPrefix("|") ? "\n" : " ")
                } else {
                    fields[key] = ([scalar(value)] + continuations).filter { !$0.isEmpty }.joined(separator: " ")
                }
            }
        }
        let name = fields["name"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        var description = fields["description"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if description.isEmpty {
            // Match Zot's support for simple Markdown skills without metadata.
            description = lines.dropFirst(bodyStart).map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.hasPrefix("#") } ?? ""
        }
        return Skill(name: name.flatMap { $0.isEmpty ? nil : $0 } ?? directory, description: description, path: path)
    }

    private static func scalar(_ value: String) -> String {
        // Generated MCP skills use JSON-quoted YAML strings, including escapes.
        if value.hasPrefix("\""), let decoded = try? JSONDecoder().decode(String.self, from: Data(value.utf8)) {
            return decoded
        }
        if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return value.components(separatedBy: " #").first ?? value
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}
