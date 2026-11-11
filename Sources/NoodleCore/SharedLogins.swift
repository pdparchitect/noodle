import Foundation

/// Keeps every running bot on a harness login using the same, current copy of it.
/// A restricted bot's refresh is handed to the others as soon as it lands, and a
/// Codex login is refreshed here before its bots would each try to.
public final class SharedLogins: @unchecked Sendable {
    public static let shared = SharedLogins()

    private struct Bot {
        let provider: HarnessProvider
        let workspace: URL
        let loginHome: URL
        let secret: (String, String) throws -> Data?
        let writeSecret: ((String, String, Data) throws -> Void)?
        let restricted: Bool
        let executable: URL
        /// The account's environment, for Codex's own renewal.
        let environment: [String: String]
    }

    private let queue = DispatchQueue(label: "Noodle.shared-logins")
    private let refreshQueue = DispatchQueue(label: "Noodle.shared-logins.refresh")
    private var bots: [ObjectIdentifier: Bot] = [:]
    private var timer: DispatchSourceTimer?
    /// Guarded by the refresh queue.
    private var failedRefreshes: [URL: Date] = [:]

    public func add(_ owner: AnyObject, provider: HarnessProvider, workspace: URL, loginHome: URL,
                    secret: @escaping (String, String) throws -> Data?, writeSecret: ((String, String, Data) throws -> Void)?,
                    restricted: Bool, executable: URL, environment: [String: String]) {
        queue.async { [self] in
            bots[ObjectIdentifier(owner)] = Bot(provider: provider, workspace: workspace, loginHome: loginHome,
                                                secret: secret, writeSecret: writeSecret, restricted: restricted, executable: executable,
                                                environment: environment)
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(2))
            timer.setEventHandler { [weak self] in self?.keepCurrent() }
            timer.resume()
            self.timer = timer
        }
    }

    /// A bot that refreshed just before stopping still hands its login back.
    public func remove(_ owner: AnyObject) {
        queue.async { [self] in
            guard let bot = bots.removeValue(forKey: ObjectIdentifier(owner)) else { return }
            if bot.restricted { try? RestrictedHarnessStorage.exchange(provider: bot.provider, workspace: bot.workspace, loginHome: bot.loginHome) }
        }
    }

    private func keepCurrent() {
        let running = Array(bots.values)
        var refreshed = Set<URL>()
        for bot in running where bot.provider == .codex && refreshed.insert(bot.loginHome).inserted {
            refreshCodexIfDue(loginHome: bot.loginHome, executable: bot.executable, environment: bot.environment)
        }
        var renewed = Set<URL>()
        for bot in running where bot.provider == .claudeCode && bot.restricted && renewed.insert(bot.loginHome).inserted {
            refreshClaudeIfDue(workspace: bot.workspace, loginHome: bot.loginHome, executable: bot.executable)
        }
        // Each Keychain item is read once per round, however many bots share it.
        var items: [String: Data?] = [:]
        // The first pass collects a refresh; the second passes it to the bots before it.
        for _ in 0..<2 {
            for bot in running where bot.restricted {
                let key = { (service: String, account: String) in [bot.loginHome.path, service, account].joined(separator: "\n") }
                try? RestrictedHarnessStorage.exchange(provider: bot.provider, workspace: bot.workspace, loginHome: bot.loginHome,
                    secret: { service, account in
                        if let item = items[key(service, account)] { return item }
                        let item = try? bot.secret(service, account)
                        items[key(service, account)] = item
                        return item
                    },
                    writeSecret: bot.writeSecret.map { write in
                        { service, account, data in
                            try write(service, account, data)
                            items[key(service, account)] = data
                        }
                    })
            }
        }
    }

    /// Renews a Claude login in one bot's copy before Claude Code would; the exchange
    /// that follows hands the renewal to every other bot on the login.
    public func refreshClaudeIfDue(workspace: URL, loginHome: URL, executable: URL) {
        refreshQueue.sync {
            let key = loginHome.appendingPathComponent(".claude", isDirectory: true)
            guard failedRefreshes[key].map({ Date().timeIntervalSince($0) > 300 }) ?? true else { return }
            let bot = HarnessLoginLog.bot(workspace)
            var due: Data?
            let renewed: Bool
            do {
                renewed = try RestrictedHarnessStorage.refreshLogin(provider: .claudeCode, workspace: workspace) { login in
                    guard ClaudeLoginRefresh.isDue(login) else { return nil }
                    due = login
                    HarnessLoginLog.logger.notice("refresh-start bot=\(bot, privacy: .public) harness=claude-code login=\(HarnessLoginLog.fingerprint(login), privacy: .public) expires-in=\(ClaudeLoginRefresh.expiresIn(login) ?? 0)s")
                    return try ClaudeLoginRefresh.refresh(login, executable: executable)
                }
            } catch {
                renewed = false
                if due != nil { HarnessLoginLog.logger.error("refresh-failed bot=\(bot, privacy: .public) harness=claude-code error=\(String(describing: type(of: error)), privacy: .public)") }
            }
            guard let due else { return }
            failedRefreshes[key] = renewed ? nil : Date()
            HarnessLoginLog.logger.notice("refresh-end bot=\(bot, privacy: .public) harness=claude-code login=\(HarnessLoginLog.fingerprint(due), privacy: .public) written=\(renewed)")
        }
    }

    /// Waits for the refresh, so a bot starting on a due login starts on the new one.
    public func refreshCodexIfDue(loginHome: URL, executable: URL, environment: [String: String]) {
        refreshQueue.sync {
            let home = loginHome.appendingPathComponent(".codex", isDirectory: true)
            guard let files = try? WorkspaceMailbox(workspace: loginHome, path: ".codex"), files.contains("auth.json"),
                  let auth = try? files.read("auth.json", limit: 1_048_576), CodexLoginRefresh.isDue(auth),
                  failedRefreshes[home].map({ Date().timeIntervalSince($0) > 3_600 }) ?? true else { return }
            HarnessLoginLog.logger.notice("refresh-start harness=codex login=\(HarnessLoginLog.fingerprint(auth), privacy: .public)")
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var succeeded = false
            Task { @MainActor in
                let provider = CodexSetupProvider(codexHome: home, environment: environment)
                let status = try? await provider.refresh(for: HarnessInstallation(provider: .codex, executablePath: executable.path))
                succeeded = status == .authenticated
                done.signal()
            }
            if done.wait(timeout: .now() + 30) == .timedOut { succeeded = false }
            failedRefreshes[home] = succeeded ? nil : Date()
            let renewed = (try? files.read("auth.json", limit: 1_048_576)).map { HarnessLoginLog.fingerprint($0) } ?? "none"
            HarnessLoginLog.logger.notice("refresh-end harness=codex login=\(HarnessLoginLog.fingerprint(auth), privacy: .public) new=\(renewed, privacy: .public) renewed=\(succeeded)")
        }
    }
}
