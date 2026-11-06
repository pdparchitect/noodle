import CryptoKit
import Foundation
import LocalAuthentication
import OSLog
import ProductIdentity
import Security

/// The trusted host copies login material only. Native histories, settings,
/// hooks, MCP connections, and skills are never imported from a shared account.
public enum RestrictedHarnessStorage {
    public static func home(workspace: URL) -> URL { workspace.appendingPathComponent(".noodle/home") }

    public static func prepare(provider: HarnessProvider, workspace: URL, loginHome: URL, settingsHome: URL? = nil,
                               now: Date = Date(),
                               secret: (String, String) throws -> Data? = readSecret,
                               writeSecret: ((String, String, Data) throws -> Void)? = nil) throws {
        _ = try WorkspaceMailbox(workspace: workspace, path: ".noodle/home", create: true)
        _ = try WorkspaceMailbox(workspace: workspace, path: ".noodle/tmp", create: true)
        guard provider != .apple else { return }
        if provider == .openCode { try OpenCodeStorage.prepareDirectories(workspace: workspace); return }
        guard let accountPath = accountPath(provider) else { throw HarnessSetupError("Unsupported restricted harness storage.") }
        let destination = try WorkspaceMailbox(workspace: workspace, path: ".noodle/home/" + accountPath, create: true)
        let runtime = try WorkspaceMailbox(workspace: AgentStorageLayout(workspace: workspace).package, path: "runtime")
        let shared = try SharedLogin(provider: provider, workspace: workspace, loginHome: loginHome, accountPath: accountPath)
        // A copy of a login the bot no longer uses goes, even when no login replaces it.
        for name in loginNames(provider) where runtime.contains(SharedLogin.stamp(provider, name)) && !shared.holds(name, runtime: runtime) {
            destination.remove(name)
            runtime.remove(SharedLogin.stamp(provider, name))
            runtime.remove(failedStamp(provider, name))
        }
        func seed(_ data: Data, name: String) throws {
            let stamp = "auth-seed-\(provider.rawValue)-\(name).sha256"
            let fingerprint = Data(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().utf8)
            if destination.contains(name), (try? runtime.read(stamp, limit: 128)) == fingerprint { return }
            try destination.writeData(data, named: name)
            try runtime.writeData(fingerprint, named: stamp)
        }
        func share(_ name: String, from origin: SharedLogin.Origin = .file, writeBack: ((Data) throws -> Data?)? = nil) throws {
            guard try shared.exchange(name, from: origin, destination: destination, runtime: runtime, writeBack: writeBack)
            else { throw missing(provider) }
        }
        func sourceData(_ name: String, in home: URL? = nil) throws -> Data? {
            let source = try WorkspaceMailbox(workspace: home ?? loginHome, path: accountPath)
            return source.contains(name) ? try source.read(name, limit: 1_048_576) : nil
        }
        switch provider {
        case .claudeCode:
            // Noodle's sign-in uses the standard Claude.ai account. The native
            // CLI prefers this exact Keychain item, with a file fallback.
            guard let data = try secret("Claude Code-credentials", NSUserName()) ?? sourceData(".credentials.json"),
                  let login = try claudeLogin(data) else { throw missing(provider) }
            try withoutActuallyEscaping(secret) { secret in
                try share(".credentials.json", from: .item(login),
                          writeBack: writeSecret.map { claudeWriteBack(over: login, secret: secret, write: $0) })
            }
        case .codex, .grokBuild:
            try share("auth.json")
            if provider == .codex {
                // Model routing is not a login, so it can come from the person's own settings.
                let routingHome = settingsHome ?? loginHome
                let routing = try CodexModelRouting(config: sourceData("config.toml", in: routingHome),
                                                    codexHome: routingHome.appendingPathComponent(accountPath))
                if let catalogue = routing.catalogue { try seed(catalogue, name: CodexModelRouting.catalogueName) }
                try seed(Data(("cli_auth_credentials_store = \"file\"\n"
                    + routing.config(catalogue: destination.url.appendingPathComponent(CodexModelRouting.catalogueName))).utf8),
                    name: "config.toml")
            }
        case .fx:
            let settings = try sourceData("settings.json").flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            // Only provider/model selection is carried across, never executable configuration.
            var selected = settings.filter { ["provider", "credential_source", "models", "effort", "fast_mode"].contains($0.key) }
            selected["auto_upgrade"] = false
            switch settings["provider"] as? String ?? "gateway" {
            case "codex", "chatgpt": try share("chatgpt-auth.json")
            case "grok": try share("grok-auth.json")
            default:
                if settings["credential_source"] as? String == "stored_key" {
                    if try sourceData("api-key") != nil { try share("api-key") }
                    else if let key = try secret("FX_AI_GATEWAY_API_KEY", NSUserName()) { try share("api-key", from: .item(key)) }
                    else { throw missing(provider) }
                    selected["credential_source"] = "ai_gateway_api_key"
                } else if try sourceData("auth.json") != nil {
                    try share("auth.json")
                } else if let session = try secret("FX_OAUTH_SESSION_V1", NSUserName()) {
                    try share("auth.json", from: .item(session))
                } else { throw missing(provider) }
            }
            try seed(JSONSerialization.data(withJSONObject: selected, options: [.sortedKeys]), name: "settings.json")
        case .muse:
            guard let data = try sourceData("auth.json"),
                  var auth = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let providers = auth["providers"] as? [String: Any],
                  var meta = providers["meta"] as? [String: Any] else { throw missing(provider) }
            if meta["storage"] as? String == "keychain" {
                guard let data = try secret("ai.meta.dev.credentials", "meta"),
                      let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw missing(provider) }
                for (key, value) in payload where key != "secret_schema_version" { meta[key] = value }
            }
            meta["storage"] = "file"
            auth["providers"] = ["meta": meta]
            try share("auth.json", from: .item(JSONSerialization.data(withJSONObject: auth, options: [.sortedKeys])))
        case .antigravity:
            // The CLI keeps its login in this Keychain item, or in this file when the
            // Keychain is out of reach, as it is for a profile and inside the sandbox.
            if let login = try secret("gemini", "antigravity").flatMap(AntigravityProtocol.fileLogin) {
                try share("antigravity-oauth-token", from: .item(login))
            } else {
                try share("antigravity-oauth-token")
            }
        default: break
        }
        for name in loginNames(provider) {
            guard let note = RefusedLogin(runtime, provider, name) else { continue }
            // A note of the login the bot holds is kept once it lapses, so a further refusal waits longer.
            guard note.login == (try? runtime.read(SharedLogin.stamp(provider, name), limit: 256)) else {
                runtime.remove(failedStamp(provider, name))
                continue
            }
            if now < note.until { throw refused(provider) }
        }
    }

    /// Hands a login a running bot refreshed to the login it shares, and the
    /// shared login to the bot. A Keychain login the person's own harness
    /// refreshed meanwhile replaces both, since its refresh spent the bot's token.
    /// Given `writeSecret`, a bot's refresh goes into the Keychain item too, since
    /// it spent the token the person's own harness holds there.
    public static func exchange(provider: HarnessProvider, workspace: URL, loginHome: URL,
                                secret: (String, String) throws -> Data? = { _, _ in nil },
                                writeSecret: ((String, String, Data) throws -> Void)? = nil) throws {
        guard let accountPath = accountPath(provider) else { return }
        let destination = try WorkspaceMailbox(workspace: workspace, path: ".noodle/home/" + accountPath)
        let runtime = try WorkspaceMailbox(workspace: AgentStorageLayout(workspace: workspace).package, path: "runtime")
        let shared = try SharedLogin(provider: provider, workspace: workspace, loginHome: loginHome, accountPath: accountPath)
        let item: Data? = switch provider {
        case .claudeCode: (try? secret("Claude Code-credentials", NSUserName())).flatMap { try? claudeLogin($0) }
        case .antigravity: (try? secret("gemini", "antigravity")).flatMap(AntigravityProtocol.fileLogin)
        default: nil
        }
        try withoutActuallyEscaping(secret) { secret in
            let writeBack = provider == .claudeCode ? item.flatMap { login in
                writeSecret.map { claudeWriteBack(over: login, secret: secret, write: $0) }
            } : nil
            for name in loginNames(provider) where shared.holds(name, runtime: runtime) {
                _ = try shared.exchange(name, from: item.map { .item($0) } ?? .unknown, destination: destination, runtime: runtime,
                                        writeBack: writeBack)
            }
        }
    }

    /// Replaces a running bot's login with `refresh`'s renewal of it, unless the bot
    /// changed it meanwhile. The next exchange hands it on like the bot's own refresh.
    public static func refreshLogin(provider: HarnessProvider, workspace: URL, refresh: (Data) throws -> Data?) throws -> Bool {
        guard let accountPath = accountPath(provider), let name = loginNames(provider).first else { return false }
        let copy = try WorkspaceMailbox(workspace: workspace, path: ".noodle/home/" + accountPath)
        guard copy.contains(name) else { return false }
        let login = try copy.read(name, limit: 1_048_576)
        guard let renewed = try refresh(login), renewed != login else { return false }
        var replaced = false
        try copy.withLock(".refresh.lock", wait: true) {
            guard try copy.read(name, limit: 1_048_576) == login else { return }
            try copy.writeData(renewed, named: name)
            replaced = true
        }
        return replaced
    }

    /// Deletes the copy bots shared of the login in `loginHome`, for every harness: bots
    /// used to share the logins of the harnesses' CLIs, which they no longer use.
    // TODO(0.77.0): remove with its calls in NoodleStore.reload and Hub.init (TODO(Hub 0.44.0)) and
    // RestrictedHarnessStorageTests.testSharedCopiesOfTheCLIsOwnLoginsAreRemoved. Milestones: 0.76.0, Hub 0.43.0.
    public static func removeSharedLogins(root: URL, loginHome: URL) {
        for provider in HarnessProvider.allCases { removeSharedLogin(provider: provider, root: root, loginHome: loginHome) }
    }

    /// Deletes the copy bots shared of one harness's login in `loginHome`. `root` is Noodle's storage.
    public static func removeSharedLogin(provider: HarnessProvider, root: URL, loginHome: URL) {
        guard let accountPath = accountPath(provider) else { return }
        let folder = AgentStorageLayout.canonicalURL(root).appendingPathComponent("HarnessLogins", isDirectory: true)
            .appendingPathComponent(SharedLogin.key(provider: provider, loginHome: loginHome, accountPath: accountPath), isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
    }

    /// Notes that the login the bot holds was refused. Starting again on it at once
    /// would only show the bot as ready, so `prepare` refuses it for a while: five
    /// minutes, twice as long after each further refusal of the same login, up to
    /// four hours, and never past the moment its access token expires, when the
    /// harness refreshes it. A new sign-in or another bot's refresh ends that at once.
    public static func loginFailed(provider: HarnessProvider, workspace: URL, now: Date = Date()) throws {
        let runtime = try WorkspaceMailbox(workspace: AgentStorageLayout(workspace: workspace).package, path: "runtime")
        let expiry = provider == .claudeCode ? claudeExpiry(workspace: workspace) : nil
        for name in loginNames(provider) where runtime.contains(SharedLogin.stamp(provider, name)) {
            let login = try runtime.read(SharedLogin.stamp(provider, name), limit: 256)
            let previous = RefusedLogin(runtime, provider, name)
            let refusals = previous?.login == login ? (previous?.refusals ?? 0) + 1 : 1
            var until = now.addingTimeInterval(min(5 * 60 * pow(2, Double(min(refusals, 16) - 1)), 4 * 60 * 60))
            if let expiry, expiry > now { until = min(until, expiry) }
            try runtime.writeData(RefusedLogin(login: login, until: until, refusals: refusals).data, named: failedStamp(provider, name))
            HarnessLoginLog.logger.error("login-refused bot=\(HarnessLoginLog.bot(workspace), privacy: .public) harness=\(provider.rawValue, privacy: .public) login=\(HarnessLoginLog.fingerprint(stamp: login), privacy: .public) refusals=\(refusals) expires-in=\(Int((expiry ?? now).timeIntervalSince(now)))s")
        }
    }

    /// Whether the next start would hand the bot the login it was refused with, while
    /// that refusal holds; asked before the start so the bot never shows as ready on it.
    /// Only Claude Code notes refused logins.
    public static func refusedAgain(provider: HarnessProvider, workspace: URL, loginHome: URL, now: Date = Date(),
                                    secret: (String, String) throws -> Data? = readSecret) -> Bool {
        guard provider == .claudeCode, let accountPath = accountPath(provider),
              let runtime = try? WorkspaceMailbox(workspace: AgentStorageLayout(workspace: workspace).package, path: "runtime"),
              let note = RefusedLogin(runtime, provider, ".credentials.json"), now < note.until,
              let shared = try? SharedLogin(provider: provider, workspace: workspace, loginHome: loginHome, accountPath: accountPath)
        else { return false }
        let source = try? WorkspaceMailbox(workspace: loginHome, path: accountPath)
        let file = source.flatMap { $0.contains(".credentials.json") ? try? $0.read(".credentials.json", limit: 1_048_576) : nil }
        guard let data = (try? secret("Claude Code-credentials", NSUserName())) ?? file,
              let login = try? claudeLogin(data) else { return false }
        let destination = try? WorkspaceMailbox(workspace: workspace, path: ".noodle/home/" + accountPath)
        return shared.next(".credentials.json", from: .item(login), destination: destination, runtime: runtime)
            .map(shared.tag) == note.login
    }

    /// When a start on the login the harness refused is allowed again, past once that
    /// refusal lapsed; nil when no refusal is noted. Reads no login.
    public static func refusedUntil(provider: HarnessProvider, workspace: URL) -> Date? {
        guard let runtime = try? WorkspaceMailbox(workspace: AgentStorageLayout(workspace: workspace).package, path: "runtime") else { return nil }
        return loginNames(provider).compactMap { RefusedLogin(runtime, provider, $0)?.until }.max()
    }

    /// Lets the next start use the refused login: the person asked to retry, or the login worked after all.
    public static func forgetRefusedLogin(provider: HarnessProvider, workspace: URL) {
        guard let runtime = try? WorkspaceMailbox(workspace: AgentStorageLayout(workspace: workspace).package, path: "runtime") else { return }
        for name in loginNames(provider) where runtime.contains(failedStamp(provider, name)) {
            runtime.remove(failedStamp(provider, name))
        }
    }

    /// Worded so the runtime recognises it as a sign-in failure.
    public static func refused(_ provider: HarnessProvider) -> HarnessSetupError {
        HarnessSetupError("Not logged in: \(provider.displayName) \(refusal)")
    }

    /// Whether a start failed because `prepare` or the host refused the login, so it reached no harness.
    public static func isRefusal(_ detail: String) -> Bool { detail.contains(refusal) }

    private static let refusal = "refused this login and nobody has signed in since. Sign in to the harness, then retry."

    private static func failedStamp(_ provider: HarnessProvider, _ name: String) -> String {
        "auth-failed-\(provider.rawValue)-\(name).sha256"
    }

    /// The refused login, as the tag of its seed, until when a start on it is refused,
    /// and how many times in a row it was refused, one per line.
    private struct RefusedLogin {
        let login: Data
        let until: Date
        let refusals: Int

        init(login: Data, until: Date, refusals: Int) {
            self.login = login
            self.until = until
            self.refusals = refusals
        }

        init?(_ runtime: WorkspaceMailbox, _ provider: HarnessProvider, _ name: String) {
            guard runtime.contains(RestrictedHarnessStorage.failedStamp(provider, name)),
                  let data = try? runtime.read(RestrictedHarnessStorage.failedStamp(provider, name), limit: 256) else { return nil }
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
            guard let login = lines.first, !login.isEmpty else { return nil }
            self.login = Data(login.utf8)
            // A note without a time lapsed long ago.
            until = lines.dropFirst().first.flatMap { TimeInterval($0) }.map(Date.init(timeIntervalSince1970:)) ?? .distantPast
            refusals = lines.dropFirst(2).first.flatMap { Int($0) } ?? 1
        }

        var data: Data {
            Data("\(String(decoding: login, as: UTF8.self))\n\(until.timeIntervalSince1970)\n\(refusals)".utf8)
        }
    }

    /// When the access token of the Claude Code login the bot holds expires.
    private static func claudeExpiry(workspace: URL) -> Date? {
        guard let home = try? WorkspaceMailbox(workspace: workspace, path: ".noodle/home/.claude"), home.contains(".credentials.json"),
              let data = try? home.read(".credentials.json", limit: 1_048_576),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let milliseconds = ((payload["claudeAiOauth"] as? [String: Any])?["expiresAt"] as? NSNumber)?.doubleValue
        else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    /// Replaces only the Claude.ai login in the item, and only while the item still
    /// holds the login the bot refreshed from; a new sign-in there wins instead.
    /// Returns the login now in the item.
    private static func claudeWriteBack(over login: Data, secret: @escaping (String, String) throws -> Data?,
                                        write: @escaping (String, String, Data) throws -> Void) -> (Data) throws -> Data? {
        { copy in
            func oauth(_ data: Data) throws -> [String: Any]? {
                (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["claudeAiOauth"] as? [String: Any]
            }
            guard let refreshed = try claudeLogin(copy), let new = try oauth(refreshed), let old = try oauth(login),
                  let token = new["refreshToken"] as? String, !token.isEmpty, token != old["refreshToken"] as? String,
                  let current = try secret("Claude Code-credentials", NSUserName()), try claudeLogin(current) == login,
                  var payload = try JSONSerialization.jsonObject(with: current) as? [String: Any] else { return nil }
            payload["claudeAiOauth"] = new
            try write("Claude Code-credentials", NSUserName(), JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
            return refreshed
        }
    }

    /// Only the Claude.ai OAuth login, never other integrations in the payload.
    private static func claudeLogin(_ data: Data) throws -> Data? {
        guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = payload["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth], options: [.sortedKeys])
    }

    /// Codex routes every model through the one provider its config selects, so
    /// custom models need that choice, the provider tables and the model catalogue.
    /// Nothing else is carried, and neither is a provider's `auth` command.
    struct CodexModelRouting {
        static let catalogueName = "model-catalog.json"
        private(set) var provider: String?
        private(set) var tables: [String] = []
        private(set) var catalogue: Data?

        init(config: Data?, codexHome: URL) throws {
            guard let config else { return }
            var table: [String]?, keep = false, depth = 0, multiline: String?
            func close() {
                guard keep, var table else { return }
                while table.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { table.removeLast() }
                tables.append(table.joined(separator: "\n"))
            }
            for line in String(decoding: config, as: UTF8.self).components(separatedBy: .newlines) {
                if let delimiter = multiline {
                    if keep { table?.append(line) }
                    if line.contains(delimiter) { multiline = nil }
                    continue
                }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") {
                    close()
                    let path = trimmed.hasPrefix("[[") ? [] : Self.headerPath(trimmed)
                    keep = path.count >= 2 && path[0] == "model_providers" && !path.dropFirst(2).contains("auth")
                    depth = path.count
                    table = [line]
                    continue
                }
                if let delimiter = ["\"\"\"", "'''"].first(where: { trimmed.components(separatedBy: $0).count == 2 }) {
                    multiline = delimiter
                }
                if table == nil {
                    switch Self.key(trimmed) {
                    case "model_provider": provider = Self.string(trimmed)
                    case "model_catalog_json": catalogue = try Self.string(trimmed).flatMap { try Self.catalogue($0, codexHome: codexHome) }
                    default: break
                    }
                } else if keep, depth > 2 || Self.key(trimmed) != "auth" {
                    table?.append(line)
                }
            }
            close()
        }

        func config(catalogue path: URL) -> String {
            var lines: [String] = []
            if let provider { lines.append("model_provider = " + Self.quoted(provider)) }
            if catalogue != nil { lines.append("model_catalog_json = " + Self.quoted(path.path)) }
            return (lines + tables.map { "\n" + $0 }).map { $0 + "\n" }.joined()
        }

        private static func key(_ line: String) -> String? {
            guard let equals = line.firstIndex(of: "=") else { return nil }
            return line[..<equals].trimmingCharacters(in: .whitespaces)
        }

        /// A single-line basic or literal string value; anything else is ignored.
        private static func string(_ line: String) -> String? {
            guard let equals = line.firstIndex(of: "=") else { return nil }
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("'"), let end = value.dropFirst().firstIndex(of: "'") {
                return String(value[value.index(after: value.startIndex)..<end])
            }
            guard value.hasPrefix("\"") else { return nil }
            // TOML basic strings escape like JSON strings; read up to the closing quote.
            var escaped = false, end: String.Index?
            for index in value.indices.dropFirst() {
                if escaped { escaped = false } else if value[index] == "\\" { escaped = true } else if value[index] == "\"" { end = index; break }
            }
            guard let end else { return nil }
            value = String(value[...end])
            return try? JSONDecoder().decode(String.self, from: Data(value.utf8))
        }

        private static func quoted(_ value: String) -> String {
            String(decoding: (try? JSONEncoder().encode(value)) ?? Data("\"\"".utf8), as: UTF8.self)
                .replacingOccurrences(of: "\\/", with: "/")
        }

        private static func headerPath(_ header: String) -> [String] {
            guard let close = header.lastIndex(of: "]") else { return [] }
            var parts: [String] = [], current = "", quote: Character?
            for character in header[header.index(after: header.startIndex)..<close] {
                if let open = quote {
                    if character == open { quote = nil } else { current.append(character) }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == "." {
                    parts.append(current.trimmingCharacters(in: .whitespaces)); current = ""
                } else {
                    current.append(character)
                }
            }
            return parts + [current.trimmingCharacters(in: .whitespaces)]
        }

        private static func catalogue(_ path: String, codexHome: URL) throws -> Data? {
            let expanded = (path as NSString).expandingTildeInPath
            let url = (expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : codexHome.appendingPathComponent(expanded))
                .resolvingSymlinksInPath()
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
            guard (attributes[.size] as? NSNumber)?.intValue ?? .max <= 4_194_304 else {
                throw HarnessSetupError("Codex’s model catalogue is too large.")
            }
            return try Data(contentsOf: url)
        }
    }

    private static func accountPath(_ provider: HarnessProvider) -> String? {
        switch provider {
        case .codex: ".codex"
        case .claudeCode: ".claude"
        case .fx: ".fx"
        case .grokBuild: ".grok"
        case .muse: ".config/muse"
        case .antigravity: ".gemini/antigravity-cli"
        default: nil
        }
    }

    private static func loginNames(_ provider: HarnessProvider) -> [String] {
        switch provider {
        case .codex, .grokBuild, .muse: ["auth.json"]
        case .claudeCode: [".credentials.json"]
        case .fx: ["chatgpt-auth.json", "grok-auth.json", "api-key", "auth.json"]
        case .antigravity: ["antigravity-oauth-token"]
        default: []
        }
    }

    /// Every bot on one login holds a copy of it. Refresh tokens are single use,
    /// so the first copy to refresh spends the token the others hold. Whatever a
    /// bot refreshed is handed back here and reaches the others before they need it.
    private struct SharedLogin {
        enum Origin {
            case file
            /// Read from the Keychain or rewritten on the way.
            case item(Data)
            /// Between starts: wherever the bot's last start put it.
            case unknown
        }

        let provider: HarnessProvider
        let key: String
        /// A login read from a file is shared in that file, which keeps the
        /// harness's own sign-in working too.
        let source: WorkspaceMailbox?
        /// A login taken from the Keychain, or rewritten on the way, is shared in
        /// Noodle's storage beside a note of the item it came from.
        let copies: WorkspaceMailbox
        let bot: String

        init(provider: HarnessProvider, workspace: URL, loginHome: URL, accountPath: String) throws {
            self.provider = provider
            bot = HarnessLoginLog.bot(workspace)
            key = Self.key(provider: provider, loginHome: loginHome, accountPath: accountPath)
            source = try? WorkspaceMailbox(workspace: loginHome, path: accountPath)
            let root = AgentStorageLayout(workspace: workspace).package.deletingLastPathComponent().deletingLastPathComponent()
            copies = try WorkspaceMailbox(workspace: root, path: "HarnessLogins/" + key, create: true)
        }

        static func key(provider: HarnessProvider, loginHome: URL, accountPath: String) -> String {
            let identity = provider.rawValue + "\n" + loginHome.standardizedFileURL.path + "\n" + accountPath
            return SHA256.hash(data: Data(identity.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        }

        func holds(_ name: String, runtime: WorkspaceMailbox) -> Bool {
            guard let stamp = try? runtime.read(stamp(name), limit: 256) else { return false }
            return String(decoding: stamp, as: UTF8.self).hasPrefix(key + ":")
        }

        /// False when there is no login to share. `writeBack` takes a bot's refresh
        /// of a Keychain login to the item and returns what the item now holds.
        func exchange(_ name: String, from origin: Origin, destination: WorkspaceMailbox, runtime: WorkspaceMailbox,
                      writeBack: ((Data) throws -> Data?)? = nil) throws -> Bool {
            var result = false
            try copies.withLock(".lock", wait: true) {
                let store: WorkspaceMailbox?
                switch origin {
                case .file: store = source
                case .unknown: store = copies.contains(name) ? copies : source
                case .item(let login):
                    // A new sign-in, or the harness refreshing its own item, replaces the shared copy.
                    if (try? copies.read(name + ".origin", limit: 256)) != tag(login) {
                        try copies.writeData(login, named: name)
                        try copies.writeData(tag(login), named: name + ".origin")
                        HarnessLoginLog.logger.notice("login-from-item bot=\(bot, privacy: .public) harness=\(provider.rawValue, privacy: .public) login=\(HarnessLoginLog.fingerprint(login), privacy: .public)")
                    }
                    store = copies
                }
                let shared = store.flatMap { $0.contains(name) ? try? $0.read(name, limit: 1_048_576) : nil }
                let agreed = try? runtime.read(stamp(name), limit: 256)
                let copy = destination.contains(name) ? try destination.read(name, limit: 1_048_576) : nil
                if let store, let shared, let copy, takesBack(copy, shared: shared, agreed: agreed) {
                    // This bot refreshed the login since it last took it.
                    try store.writeData(copy, named: name)
                    try runtime.writeData(tag(copy), named: stamp(name))
                    HarnessLoginLog.logger.notice("login-taken-back bot=\(bot, privacy: .public) harness=\(provider.rawValue, privacy: .public) login=\(HarnessLoginLog.fingerprint(copy), privacy: .public) replaced=\(HarnessLoginLog.fingerprint(shared), privacy: .public)")
                    if case .item = origin, let written = try? writeBack?(copy) {
                        try copies.writeData(tag(written), named: name + ".origin")
                    }
                    result = true
                    return
                }
                guard let shared else { return }
                if copy != shared {
                    try destination.writeData(shared, named: name)
                    HarnessLoginLog.logger.notice("login-handed bot=\(bot, privacy: .public) harness=\(provider.rawValue, privacy: .public) login=\(HarnessLoginLog.fingerprint(shared), privacy: .public) replaced=\(copy.map { HarnessLoginLog.fingerprint($0) } ?? "none", privacy: .public)")
                }
                if agreed != tag(shared) { try runtime.writeData(tag(shared), named: stamp(name)) }
                result = true
            }
            return result
        }

        /// The login `exchange` would leave the bot holding, without exchanging anything.
        func next(_ name: String, from origin: Origin, destination: WorkspaceMailbox?, runtime: WorkspaceMailbox) -> Data? {
            let store: WorkspaceMailbox?
            switch origin {
            case .file: store = source
            case .unknown: store = copies.contains(name) ? copies : source
            case .item(let login):
                if (try? copies.read(name + ".origin", limit: 256)) != tag(login) { return login }
                store = copies
            }
            let shared = store.flatMap { $0.contains(name) ? try? $0.read(name, limit: 1_048_576) : nil }
            let agreed = try? runtime.read(stamp(name), limit: 256)
            let copy = destination.flatMap { $0.contains(name) ? try? $0.read(name, limit: 1_048_576) : nil }
            if let shared, let copy, takesBack(copy, shared: shared, agreed: agreed) { return copy }
            return shared
        }

        /// Whether the bot's copy replaces the shared login: when the bot changed it since it
        /// last took it, unless the change is Claude Code clearing a login it could not refresh,
        /// which must never win over a working one. A working copy also replaces a cleared one.
        private func takesBack(_ copy: Data, shared: Data, agreed: Data?) -> Bool {
            guard agreed != tag(copy) else { return false }
            if agreed == tag(shared) { return works(copy) || !works(shared) }
            return works(copy) && !works(shared)
        }

        /// False only for a Claude Code login without a refresh token, as Claude Code leaves it
        /// once a refresh is refused.
        private func works(_ login: Data) -> Bool {
            guard provider == .claudeCode else { return true }
            let oauth = (try? JSONSerialization.jsonObject(with: login) as? [String: Any])?["claudeAiOauth"] as? [String: Any]
            return (oauth?["refreshToken"] as? String).map { !$0.isEmpty } ?? false
        }

        func tag(_ data: Data) -> Data {
            Data((key + ":" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()).utf8)
        }

        private func stamp(_ name: String) -> String { Self.stamp(provider, name) }

        static func stamp(_ provider: HarnessProvider, _ name: String) -> String { "auth-seed-\(provider.rawValue)-\(name).sha256" }
    }

    /// Worded so the runtime recognises it as a sign-in failure and waits for one.
    private static func missing(_ provider: HarnessProvider) -> HarnessSetupError {
        HarnessSetupError("Not logged in: \(ProductIdentity.current.name) has no \(provider.displayName) login for this bot. Please sign in to the harness in Settings, then retry startup.")
    }

    public static func readSecret(service: String, account: String) throws -> Data? {
        try readSecret(service: service, account: account, tool: securityTool)
    }

    static func readSecret(service: String, account: String,
                           tool: ([String]) throws -> (status: Int32, output: Data)) throws -> Data? {
        // Claude Code and Antigravity write their items with /usr/bin/security,
        // which leaves only that tool trusted. FX recreates its items on token
        // refresh, which drops Always Allow. A direct read would ask for the
        // login password each time.
        // A Claude Code profile's item carries its folder's digest after the name.
        guard ["Claude Code-credentials", "gemini", "FX_OAUTH_SESSION_V1", "FX_AI_GATEWAY_API_KEY"].contains(service)
                || service.hasPrefix("Claude Code-credentials-") else {
            return try readKeychainItem(service: service, account: account)
        }
        let result = try tool(["find-generic-password", "-s", service, "-a", account, "-w"])
        if result.status == 44 { return nil }
        var text = String(decoding: result.output, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        guard result.status == 0, !text.isEmpty, result.output.count <= 2_097_152 else {
            throw HarnessSetupError("macOS did not allow Noodle Agent Host to read the harness login (\(result.status)). Unlock the login keychain, then retry startup.")
        }
        // The tool prints hex when the stored bytes are not plain text.
        if text.count.isMultiple(of: 2), text.allSatisfy(\.isHexDigit) {
            var bytes = Data(), index = text.startIndex
            while index < text.endIndex {
                let next = text.index(index, offsetBy: 2)
                bytes.append(UInt8(text[index..<next], radix: 16)!)
                index = next
            }
            return bytes
        }
        return Data(text.utf8)
    }

    /// Writes a Claude Code login item the way the CLI does, through the tool it
    /// trusts. The command goes in on standard input, so the login never shows
    /// in the process list.
    public static func writeSecret(service: String, account: String, data: Data) throws {
        guard service == "Claude Code-credentials" || service.hasPrefix("Claude Code-credentials-"),
              !account.contains("\""), !account.contains("\n") else { throw HarnessSetupError("Unsupported harness login item.") }
        let hex = data.map { String(format: "%02x", $0) }.joined()
        let process = Process(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["-i"]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        input.fileHandleForWriting.write(Data("add-generic-password -U -a \"\(account)\" -s \"\(service)\" -X \"\(hex)\"\n".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HarnessSetupError("macOS did not allow Noodle Agent Host to update the harness login (\(process.terminationStatus)).")
        }
    }

    /// Deletes the Keychain item Claude Code keeps for one of Noodle's own login folders,
    /// through the tool the CLI wrote it with. The item of the person's own Claude Code,
    /// without a folder digest after its name, is never deleted.
    public static func deleteSecret(service: String, account: String) throws {
        try deleteSecret(service: service, account: account, tool: securityTool)
    }

    static func deleteSecret(service: String, account: String,
                             tool: ([String]) throws -> (status: Int32, output: Data)) throws {
        guard service.hasPrefix("Claude Code-credentials-") else { throw HarnessSetupError("Unsupported harness login item.") }
        let result = try tool(["delete-generic-password", "-s", service, "-a", account])
        // 44: there is no such item, so nobody is signed in there.
        guard result.status == 0 || result.status == 44 else {
            throw HarnessSetupError("macOS did not allow Noodle Agent Host to remove the harness login (\(result.status)). Unlock the login keychain, then try again.")
        }
    }

    private static func securityTool(_ arguments: [String]) throws -> (status: Int32, output: Data) {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, data)
    }

    private static func readKeychainItem(service: String, account: String) throws -> Data? {
        // Exact provider item only. Never enumerate Keychain or permit a prompt
        // during background startup. Access denial leaves the sandbox closed.
        let context = LAContext(); context.interactionNotAllowed = true
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data, data.count <= 1_048_576 else {
            throw HarnessSetupError("macOS did not allow Noodle Agent Host to read the harness login (\(status)). Grant that helper access to the provider's login item in Keychain Access, then retry startup.")
        }
        return data
    }
}

/// Login renewals, hand-overs and refusals for every harness, told apart by fingerprint
/// only: never a token, a path or a raw error.
public enum HarnessLoginLog {
    public static let logger = Logger(subsystem: RuntimeDiagnostics.subsystem, category: "logins")

    /// The first digits of the login's hash, as the bot's seed stamp records it.
    public static func fingerprint(_ login: Data) -> String {
        SHA256.hash(data: login).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    /// The same digits read from a stamp, which already holds the hash.
    static func fingerprint(stamp: Data) -> String {
        String(String(decoding: stamp, as: UTF8.self).split(separator: ":").last?.prefix(8) ?? "none")
    }

    /// The bot's ID, the name of the folder that holds its workspace.
    public static func bot(_ workspace: URL) -> String { workspace.deletingLastPathComponent().lastPathComponent }
}

/// Claude Code renews its login only in the last minutes before it expires, and
/// every bot on the login does so then, though only the first renewal works. The
/// Agent Host renews it once, earlier, and the bots take the renewal.
public enum ClaudeLoginRefresh {
    public static let margin: TimeInterval = 30 * 60

    /// Seconds until `login`'s access token expires.
    public static func expiresIn(_ login: Data, now: Date = Date()) -> Int? {
        guard let expires = (((try? JSONSerialization.jsonObject(with: login) as? [String: Any])?["claudeAiOauth"] as? [String: Any])?["expiresAt"] as? NSNumber)?.doubleValue
        else { return nil }
        return Int(Date(timeIntervalSince1970: expires / 1000).timeIntervalSince(now))
    }

    /// Reads only the expiry, never a token.
    public static func isDue(_ login: Data, now: Date = Date()) -> Bool {
        guard let oauth = (try? JSONSerialization.jsonObject(with: login) as? [String: Any])?["claudeAiOauth"] as? [String: Any],
              let token = oauth["refreshToken"] as? String, !token.isEmpty,
              let expires = (oauth["expiresAt"] as? NSNumber)?.doubleValue else { return false }
        return Date(timeIntervalSince1970: expires / 1000).timeIntervalSince(now) < margin
    }

    /// Has Claude Code renew `login` itself. It renews a login about to expire when it
    /// starts, so a private copy marked as expiring within the minute is started and left
    /// idle until it is renewed. Claude Code tries the Keychain first through `security`,
    /// found on the path; there is no keychain in the private home, so macOS would ask the
    /// person to reset theirs. Leaving `/usr/bin` off the path keeps the login in its file,
    /// as the bots' sandbox does. Nil when Claude Code did not renew it in time.
    public static func refresh(_ login: Data, executable: URL, timeout: TimeInterval = 30) throws -> Data? {
        guard var payload = try JSONSerialization.jsonObject(with: login) as? [String: Any],
              var oauth = payload["claudeAiOauth"] as? [String: Any],
              let token = oauth["refreshToken"] as? String else { return nil }
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-claude-refresh-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let account = home.appendingPathComponent(".claude", isDirectory: true)
        try FileManager.default.createDirectory(at: account, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        oauth["expiresAt"] = Int((Date().timeIntervalSince1970 + 60) * 1000)
        payload["claudeAiOauth"] = oauth
        let file = account.appendingPathComponent(".credentials.json")
        try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)

        let process = Process(), input = Pipe()
        BrowserlessLaunch.configure(process, executable: executable,
                                    arguments: ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"])
        process.currentDirectoryURL = home
        process.environment = ["HOME": home.path, "CLAUDE_CONFIG_DIR": account.path, "USER": NSUserName(), "LOGNAME": NSUserName(),
                               "PATH": "/bin:/usr/sbin:/sbin", "TMPDIR": home.path, "DISABLE_AUTOUPDATER": "1"]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            try? input.fileHandleForWriting.close()
        }
        let start = Date(), end = start.addingTimeInterval(timeout)
        while Date() < end {
            if let data = try? Data(contentsOf: file),
               let renewed = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["claudeAiOauth"] as? [String: Any],
               let next = renewed["refreshToken"] as? String, !next.isEmpty, next != token {
                HarnessLoginLog.logger.notice("refresh-renewed harness=claude-code login=\(HarnessLoginLog.fingerprint(login), privacy: .public) new=\(HarnessLoginLog.fingerprint(data), privacy: .public) took=\(Int(Date().timeIntervalSince(start)))s")
                return data
            }
            guard process.isRunning else {
                HarnessLoginLog.logger.error("refresh-exited harness=claude-code login=\(HarnessLoginLog.fingerprint(login), privacy: .public) status=\(process.terminationStatus) took=\(Int(Date().timeIntervalSince(start)))s")
                return nil
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        HarnessLoginLog.logger.error("refresh-timed-out harness=claude-code login=\(HarnessLoginLog.fingerprint(login), privacy: .public) after=\(Int(timeout))s")
        return nil
    }
}
