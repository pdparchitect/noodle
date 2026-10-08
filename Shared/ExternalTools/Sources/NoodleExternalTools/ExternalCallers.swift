import Darwin
import Foundation
import Security

public struct ExternalToolsError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// The app a command-line call comes from, such as Claude Code or Terminal. People approve it
/// by name; `key` is what is remembered.
public struct ExternalLauncher: Codable, Hashable, Sendable {
    /// `team:TEAM:IDENTIFIER` for a signed app, `cdhash:HASH` for one signed without a team,
    /// `path:PATH` for the rest.
    public var key: String
    public var name: String
    public var path: String
    /// Signed by a developer Apple identified, or part of macOS, so its name is its own.
    public var identified: Bool
    /// Runs whatever it is given, such as Terminal or Python, so approving it lets in anything run through it.
    public var broad: Bool
    public init(key: String, name: String, path: String, identified: Bool = true, broad: Bool = false) {
        self.key = key; self.name = name; self.path = path; self.identified = identified; self.broad = broad
    }

    /// What the person should know before allowing it.
    public var caution: String? {
        if !identified { return "It is not from an identified developer, so it may not be what its name says. It is \(path)." }
        if broad { return "Anything run from \(name) can then do the same." }
        return nil
    }
}

/// One process above the command-line tool, as the kernel and its code signature describe it.
public struct ExternalProcess: Equatable, Sendable {
    public var pid: Int32
    public var path: String
    public var identifier: String?
    public var team: String?
    public var cdhash: String?
    /// Part of macOS itself.
    public var platform: Bool
    public var sandboxed: Bool
    public init(pid: Int32, path: String, identifier: String?, team: String?, cdhash: String?, platform: Bool, sandboxed: Bool) {
        self.pid = pid; self.path = path; self.identifier = identifier; self.team = team; self.cdhash = cdhash
        self.platform = platform; self.sandboxed = sandboxed
    }
}

/// Who started the command-line tool. The tool walks its own ancestors, which an app that runs
/// it cannot change: the tool is hardened, and the app verifies by signature that it is talking
/// to the tool. Anything sandboxed, and Noodle itself, is refused, so a bot inside Noodle cannot
/// reach past what Noodle assigned it.
public enum ExternalAncestry {
    static let forbiddenPrefix = "com.pdparchitect.noodle"
    /// Programs that only pass the call on, so the app above them is the caller.
    static let passThrough: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "tcsh", "csh", "nu",
                                           "env", "login", "sudo", "nohup", "timeout", "xargs", "script"]

    /// `chain` runs from the tool's parent upwards, without launchd.
    public static func launcher(for chain: [ExternalProcess]) throws -> ExternalLauncher {
        guard !chain.isEmpty else { throw ExternalToolsError("Cannot tell which app is running this tool.") }
        if chain.contains(where: \.sandboxed) {
            throw ExternalToolsError("Sandboxed apps cannot use this tool.")
        }
        if chain.contains(where: { $0.identifier?.hasPrefix(forbiddenPrefix) == true }) {
            throw ExternalToolsError("Noodle's bots use this app through Noodle, not this tool.")
        }
        // Only shells and macOS's own programs, as when a process cuts itself loose from whatever
        // started it: there is no app to ask the person about.
        guard let caller = chain.first(where: { process in
            let name = (process.path as NSString).lastPathComponent
            return !passThrough.contains(name) && !(process.platform && !process.path.contains(".app/"))
        }) else { throw ExternalToolsError("Cannot tell which app is running this tool. Run it from an app such as Claude Code or Terminal.") }
        // Apple's programs keep their identifier across macOS updates; their code hash does not.
        let key = if let team = caller.team, let identifier = caller.identifier { "team:\(team):\(identifier)" }
            else if caller.platform, let identifier = caller.identifier { "apple:\(identifier)" }
            else if let cdhash = caller.cdhash { "cdhash:\(cdhash)" }
            else { "path:\(caller.path)" }
        return ExternalLauncher(key: key, name: name(of: caller), path: caller.path,
                                identified: caller.team != nil || caller.platform, broad: broad(caller))
    }

    /// Terminals, editors with terminals, and interpreters. Not every such app is known; this
    /// only decides whether the person is warned.
    static let broadApps = ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.", "com.mitchellh.ghostty", "net.kovidgoyal.kitty",
                            "org.alacritty", "io.alacritty", "com.github.wez.wezterm", "co.zeit.hyper", "com.microsoft.VSCode",
                            "com.todesktop.", "dev.zed.", "com.jetbrains.", "com.apple.dt.Xcode", "com.apple.ScriptEditor2"]
    static let interpreters = ["node", "python", "ruby", "perl", "php", "deno", "bun", "osascript", "java", "lua", "pwsh", "tclsh", "expect", "Rscript", "julia"]

    static func broad(_ process: ExternalProcess) -> Bool {
        if let identifier = process.identifier, broadApps.contains(where: { identifier.hasPrefix($0) }) { return true }
        let file = (process.path as NSString).lastPathComponent
        return interpreters.contains { file == $0 || (file.hasPrefix($0) && file.dropFirst($0.count).allSatisfy { $0.isNumber || $0 == "." }) }
    }

    /// An app's own name, a team-signed tool's identifier as words ("com.anthropic.claude-code"
    /// is Claude Code), or the program's file name.
    static func name(of process: ExternalProcess) -> String {
        let components = process.path.components(separatedBy: "/")
        if let app = components.last(where: { $0.hasSuffix(".app") }) { return String(app.dropLast(4)) }
        if process.team != nil, let last = process.identifier?.components(separatedBy: ".").last, !last.isEmpty {
            return last.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
        return components.last ?? process.path
    }

    /// The caller of this process.
    public static func current() throws -> ExternalLauncher {
        var chain: [ExternalProcess] = []
        var pid = getppid()
        while pid > 1, chain.count < 64 {
            chain.append(try process(pid))
            pid = try parent(of: pid)
        }
        return try launcher(for: chain)
    }

    /// The short form, which anyone may read: the full one is refused for root's processes, such as
    /// the login Terminal and SSH put between the app and the shell.
    static func parent(of pid: Int32) throws -> Int32 {
        var info = proc_bsdshortinfo()
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdshortinfo>.size)) > 0 else {
            throw ExternalToolsError("Cannot tell which app is running this tool.")
        }
        return Int32(info.pbsi_ppid)
    }

    static func process(_ pid: Int32) throws -> ExternalProcess {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { throw ExternalToolsError("Cannot tell which app is running this tool.") }
        let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        var process = ExternalProcess(pid: pid, path: path, identifier: nil, team: nil, cdhash: nil, platform: false, sandboxed: false)
        var code: SecCode?, staticCode: SecStaticCode?, signing: CFDictionary?
        guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: pid] as CFDictionary, [], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation), &signing) == errSecSuccess,
              let info = signing as? [String: Any] else { return process }
        process.identifier = info[kSecCodeInfoIdentifier as String] as? String
        process.cdhash = (info[kSecCodeInfoUnique as String] as? Data)?.map { String(format: "%02x", $0) }.joined()
        // The signature's own claims count only once its certificates lead back to Apple.
        func valid(_ requirement: String) -> Bool {
            var compiled: SecRequirement?
            return SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess && compiled != nil
                && SecCodeCheckValidity(code, [], compiled) == errSecSuccess
        }
        if let team = info[kSecCodeInfoTeamIdentifier as String] as? String, team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }),
           valid("anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"") {
            process.team = team
        }
        process.platform = (info[kSecCodeInfoPlatformIdentifier as String] as? Int ?? 0) != 0 && valid("anchor apple")
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        process.sandboxed = entitlements?["com.apple.security.app-sandbox"] as? Bool == true
        return process
    }
}
