import CryptoKit
import Foundation
import SQLite3

/// V2 keeps credentials and conversations in one database. The host reads only
/// credential rows; every write to the bot's database runs inside its OS sandbox.
public enum OpenCodeStorage {
    public static func prepareDirectories(workspace: URL) throws {
        for path in [".agents/skills", ".noodle/home", ".noodle/tmp", ".noodle/home/.config/opencode",
                     ".noodle/home/.local/share/opencode", ".noodle/home/.local/state/opencode",
                     ".noodle/home/.cache/opencode"] {
            _ = try WorkspaceMailbox(workspace: workspace, path: path, create: true)
        }
        let config = try WorkspaceMailbox(workspace: workspace, path: ".noodle/home/.config/opencode")
        try config.writeData(Data("{\"update\":\"disable\",\"share\":\"disabled\"}\n".utf8), named: "opencode.json", replaceExisting: false)
        // V2's project walk includes every ancestor up to /. Expose only this
        // bot's managed instructions and skills through its private global scope.
        try config.symlink("AGENTS.md", destination: workspace.appendingPathComponent("AGENTS.md").path)
        try config.symlink("skills", destination: workspace.appendingPathComponent(".agents/skills").path)
    }

    public static func environment(workspace: URL) -> [String: String] {
        let home = RestrictedHarnessStorage.home(workspace: workspace)
        return ["HOME": home.path, "XDG_CONFIG_HOME": home.appendingPathComponent(".config").path,
            "XDG_DATA_HOME": home.appendingPathComponent(".local/share").path,
            "XDG_STATE_HOME": home.appendingPathComponent(".local/state").path,
            "XDG_CACHE_HOME": home.appendingPathComponent(".cache").path,
            "TMPDIR": workspace.appendingPathComponent(".noodle/tmp").path,
            "OPENCODE_DISABLE_AUTOUPDATE": "true", "OPENCODE_DISABLE_CHANNEL_DB": "true",
            "OPENCODE_DISABLE_FILEWATCHER": "true", "OPENCODE_DISABLE_PROJECT_CONFIG": "true",
            "OPENCODE_CONFIG": workspace.appendingPathComponent("opencode.json").path]
    }

    static func credentials(home: URL) throws -> [[String: Any]] {
        let url = home.appendingPathComponent(".local/share/opencode/opencode.db")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard url.resolvingSymlinksInPath() == url,
              try FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType == .typeRegular else {
            throw HarnessSetupError("OpenCode’s credential database is redirected or unavailable.")
        }
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: url.path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path), sidecar.resolvingSymlinksInPath() != sidecar {
                throw HarnessSetupError("OpenCode’s credential database is redirected.")
            }
        }
        guard let canonical = realpath(url.path, nil) else { throw HarnessSetupError("OpenCode’s credential database is unavailable.") }
        defer { free(canonical) }
        var db: OpaquePointer?
        guard sqlite3_open_v2(canonical, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            throw HarnessSetupError("Could not read OpenCode’s v2 sign-in. Run opencode auth login, then check again.")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 2000)
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 1_048_576)
        sqlite3_exec(db, "PRAGMA trusted_schema=OFF", nil, nil, nil)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, integration_id, value, active, time_created FROM credential WHERE integration_id IS NOT NULL ORDER BY id LIMIT 129", -1, &statement, nil) == SQLITE_OK else {
            throw HarnessSetupError("OpenCode’s credential schema is unsupported. Sign in with the current v2 CLI, then check again.")
        }
        defer { sqlite3_finalize(statement) }
        var result = [[String: Any]](), bytes = 0, count = 0
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { break }
            count += 1
            guard status == SQLITE_ROW, count <= 128 else { throw HarnessSetupError("Could not read OpenCode’s credential records.") }
            func text(_ column: Int32) -> String? {
                sqlite3_column_text(statement, column).map { String(cString: $0) }
            }
            guard let id = text(0), let integration = text(1), let raw = text(2),
                  FxProtocol.validIdentifier(id),
                  let data = raw.data(using: .utf8),
                  let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw HarnessSetupError("OpenCode has an unsupported credential record.")
            }
            // V2 names MCP OAuth integrations mcp_<hash>; those are never model logins.
            guard !integration.hasPrefix("mcp_"),
                  integration.range(of: #"\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}\z"#, options: .regularExpression) != nil else { continue }
            // Custom executable configuration and MCP/URL credentials are not imported.
            let allowed: Set<String>
            switch value["type"] as? String {
            case "key":
                guard let key = value["key"] as? String, !key.isEmpty else { continue }
                allowed = ["type", "key", "metadata"]
            case "oauth":
                guard value["methodID"] is String, value["access"] is String,
                      value["refresh"] is String, value["expires"] is NSNumber else { continue }
                allowed = ["type", "methodID", "access", "refresh", "expires", "metadata"]
            default: continue
            }
            let clean = value.filter { allowed.contains($0.key) }
            let encoded = try JSONSerialization.data(withJSONObject: clean, options: [.sortedKeys])
            bytes += encoded.count
            guard bytes <= 1_048_576 else { throw HarnessSetupError("OpenCode’s credential records are too large.") }
            result.append(["id": id, "integration": integration, "value": String(decoding: encoded, as: UTF8.self),
                           "active": sqlite3_column_int(statement, 3), "created": sqlite3_column_int64(statement, 4)])
        }
        return result
    }

    public static func seed(workspace: URL, loginHome: URL, executable: URL,
                            environment: [String: String], profile: String) throws -> Bool {
        try seed(credentials: credentials(home: loginHome), workspace: workspace, executable: executable,
                 environment: environment, profile: profile)
    }

    @discardableResult
    static func seed(credentials: [[String: Any]], workspace: URL, executable: URL,
                     environment: [String: String], profile: String) throws -> Bool {
        let runtime = try WorkspaceMailbox(workspace: AgentStorageLayout(workspace: workspace).package, path: "runtime")
        let account = try WorkspaceMailbox(workspace: workspace, path: ".noodle/home/.local/share/opencode")
        let source = try JSONSerialization.data(withJSONObject: credentials, options: [.sortedKeys])
        let fingerprint = Data(SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined().utf8)
        let stamp = "auth-seed-opencode.sha256"
        if account.contains("opencode.db"), (try? runtime.read(stamp, limit: 128)) == fingerprint { return !credentials.isEmpty }
        // Let the verified binary create/migrate its schema, using no shared home,
        // plugins or project configuration. No session or model turn is created.
        let bootstrap = environment.merging(["OPENCODE_DISABLE_PROJECT_CONFIG": "true", "OPENCODE_DISABLE_MODELS_FETCH": "true"]) { _, new in new }
        _ = try OpenCodeCommand.run(executable, arguments: ["auth", "list", "--standalone", "--format", "json"],
            workspace: workspace, environment: bootstrap, profile: profile)
        // SQL is passed through an unlinked stdin file, never arguments or logs.
        // Hex literals prevent credential contents from becoming SQL/CLI commands.
        func literal(_ value: String) -> String {
            "CAST(X'" + Data(value.utf8).map { String(format: "%02x", $0) }.joined() + "' AS TEXT)"
        }
        var sql = "PRAGMA trusted_schema=OFF;\nBEGIN IMMEDIATE;\nDELETE FROM credential;\n"
        for row in credentials {
            let id = literal(row["id"] as! String), integration = literal(row["integration"] as! String)
            let value = literal(row["value"] as! String)
            let active = (row["active"] as? NSNumber)?.intValue ?? 0
            let created = (row["created"] as? NSNumber)?.int64Value ?? 0
            sql += "INSERT INTO credential (id,integration_id,label,value,active,time_created,time_updated) VALUES (\(id),\(integration),'Noodle',\(value),\(active == 1 ? 1 : 0),\(created),\(created));\n"
        }
        sql += "COMMIT;\n"
        _ = try OpenCodeCommand.run(URL(fileURLWithPath: "/usr/bin/sqlite3"),
            arguments: ["-batch", "-bail", "-safe", account.url.appendingPathComponent("opencode.db").path],
            workspace: workspace, environment: environment, profile: profile, input: Data(sql.utf8), timeout: 8)
        try runtime.writeData(fingerprint, named: stamp)
        return !credentials.isEmpty
    }
}
