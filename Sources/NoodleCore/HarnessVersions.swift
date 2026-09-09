import Foundation

public struct HarnessVersion: Comparable, Equatable, Sendable {
    public let text: String
    private let numbers: [Int]
    private let prerelease: [String]

    public init?(_ text: String) {
        guard text.count < 100,
              text.range(of: #"^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"#, options: .regularExpression) != nil else { return nil }
        let release = text.components(separatedBy: "+")[0]
        let parts = release.split(separator: "-", maxSplits: 1).map(String.init)
        let numbers = parts[0].split(separator: ".").compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        self.text = text
        self.numbers = numbers
        prerelease = parts.count == 2 ? parts[1].components(separatedBy: ".") : []
    }

    public static func == (lhs: Self, rhs: Self) -> Bool { lhs.numbers == rhs.numbers && lhs.prerelease == rhs.prerelease }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.numbers != rhs.numbers { return lhs.numbers.lexicographicallyPrecedes(rhs.numbers) }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty { return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            // Muse stable builds use R-prefixed numeric revisions (R9 < R10).
            if a.hasPrefix("R"), b.hasPrefix("R"), let x = Int(a.dropFirst()), let y = Int(b.dropFirst()) { return x < y }
            if let x = Int(a), let y = Int(b) { return x < y }
            if Int(a) != nil { return true }
            if Int(b) != nil { return false }
            return a < b
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }

    public static func parseOutput(_ output: String) -> Self? {
        let pattern = #"(?<![A-Za-z0-9])v?(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else { return nil }
        return Self(String(output[range]))
    }
}

public struct HarnessVersionReport: Codable, Equatable, Sendable {
    public var installedVersion: String?
    public var latestVersion: String?
    public var compatibilityIssue: String?
    public var checkError: String?
    public var latestCheckedAt: Date?

    public init(installedVersion: String? = nil, latestVersion: String? = nil,
                compatibilityIssue: String? = nil, checkError: String? = nil, latestCheckedAt: Date? = nil) {
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.compatibilityIssue = compatibilityIssue
        self.checkError = checkError
        self.latestCheckedAt = latestCheckedAt
    }

    public var updateAvailable: Bool {
        guard let installedVersion, let latestVersion,
              let installed = HarnessVersion(installedVersion), let latest = HarnessVersion(latestVersion) else { return false }
        return installed < latest
    }
}

@MainActor public protocol HarnessVersionChecking {
    func check(_ installation: HarnessInstallation, previous: HarnessVersionReport?, forceLatest: Bool) async throws -> HarnessVersionReport
}

public enum HarnessVersionPolicy {
    public static func helpArguments(for provider: HarnessProvider) -> [String] {
        provider == .grokBuild ? ["agent", "--help"] : ["--help"]
    }

    public static func requiredOptions(for provider: HarnessProvider) -> [String] {
        switch provider {
        case .codex: return ["app-server"]
        case .claudeCode: return ["--input-format", "--output-format", "--permission-mode", "--permission-prompts", "--session-id"]
        case .fx: return ["acp"]
        case .grokBuild: return ["stdio", "--no-leader"]
        case .muse: return ["serve", "schema"]
        }
    }

    public static func compatibilityIssue(provider: HarnessProvider, help: String) -> String? {
        guard help.lowercased().contains("usage:") else { return nil }
        let missing = requiredOptions(for: provider).filter { option in
            help.range(of: "(?<![a-zA-Z0-9-])" + NSRegularExpression.escapedPattern(for: option) + "(?![a-zA-Z0-9-])",
                       options: .regularExpression) == nil
        }
        guard !missing.isEmpty else { return nil }
        return "This \(provider.displayName) installation is missing required support for \(missing.joined(separator: ", ")). Update the harness, then choose Check Again."
    }

    /// Only classify explicit CLI incompatibilities, never auth/network/model/safety failures.
    public static func startupIssue(provider: HarnessProvider, text: String) -> String? {
        let lower = text.lowercased()
        let rejection = ["unknown option", "unrecognized option", "unexpected argument", "unknown command", "unrecognized subcommand"]
        let options = requiredOptions(for: provider) + (provider == .claudeCode ? ["auth", "--effort"] : [])
        for line in lower.components(separatedBy: .newlines) {
            if rejection.contains(where: line.contains), options.contains(where: { line.contains("'\($0)'") || line.contains("\"\($0)\"") }) {
                return "\(provider.displayName) does not support a command option required by Noodle. Update the harness in Settings → Harness, then retry."
            }
        }
        return nil
    }

    public static func isBundledCodex(_ installation: HarnessInstallation) -> Bool {
        installation.provider == .codex && (installation.executablePath?.hasPrefix("/Applications/") == true)
    }

    public static func latestURL(for installation: HarnessInstallation) -> URL? {
        if isBundledCodex(installation) { return nil }
        let address: String
        switch installation.provider {
        case .codex: address = "https://api.github.com/repos/openai/codex/releases/latest"
        case .claudeCode: address = "https://api.github.com/repos/anthropics/claude-code/releases/latest"
        case .fx: address = "https://releases.fx.sh/latest.txt"
        case .grokBuild: address = "https://x.ai/cli/stable"
        case .muse: address = "https://api.meta.ai/muse-code/channels/muse-stable"
        }
        return URL(string: address)
    }

    public static func latestVersion(provider: HarnessProvider, data: Data) -> String? {
        let value: String
        if provider == .codex || provider == .claudeCode {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["prerelease"] as? Bool != true, object["draft"] as? Bool != true,
                  let tag = object["tag_name"] as? String else { return nil }
            value = tag.hasPrefix("rust-v") ? String(tag.dropFirst(6)) : tag
        } else if provider == .muse {
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["channel"] as? String == "muse-stable", object["state"] as? String == "public",
                  let version = object["version"] as? String, MuseExecutableTrust.validVersion(version) else { return nil }
            value = version
        } else { value = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        let normalized = value.hasPrefix("v") ? String(value.dropFirst()) : value
        return HarnessVersion(normalized)?.text
    }

    public static func updateGuide(for installation: HarnessInstallation) -> HarnessInstallationGuide {
        if isBundledCodex(installation) {
            return .init(command: nil, instructions: "This Codex executable is bundled with a desktop app. Update that Codex or ChatGPT app, then choose Check Again. Do not replace its bundled executable.",
                         documentationURL: URL(string: "https://developers.openai.com/codex/app/")!)
        }
        let command: String, link: String
        switch installation.provider {
        case .codex:
            command = "curl -fsSL https://chatgpt.com/codex/install.sh | sh"
            link = "https://developers.openai.com/codex/cli/"
        case .claudeCode:
            command = "claude update"
            link = "https://code.claude.com/docs/en/installation"
        case .fx:
            command = "fx upgrade"
            link = "https://fx.sh/"
        case .grokBuild:
            command = "grok update"
            link = "https://grok.com/build"
        case .muse:
            command = "curl -fsSL https://dev.meta.ai/install.sh | bash"
            link = "https://dev.meta.ai/"
        }
        return .init(command: command,
            instructions: "Run this command in Terminal, then choose Check Again. Updates follow the provider’s configured release channel; managed or pinned installs may intentionally remain on an older version. Existing bot processes keep their running version until restarted.",
            documentationURL: URL(string: link)!)
    }
}
