import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// The trusted host copies login material only. Native histories, settings,
/// hooks, MCP connections, and skills are never imported from a shared account.
public enum RestrictedHarnessStorage {
    public static func home(workspace: URL) -> URL { workspace.appendingPathComponent(".noodle/home") }

    public static func prepare(provider: HarnessProvider, workspace: URL, loginHome: URL,
                               secret: (String, String) throws -> Data? = readSecret) throws {
        _ = try WorkspaceMailbox(workspace: workspace, path: ".noodle/home", create: true)
        _ = try WorkspaceMailbox(workspace: workspace, path: ".noodle/tmp", create: true)
        guard provider != .apple else { return }
        if provider == .openCode { try OpenCodeStorage.prepareDirectories(workspace: workspace); return }
        let accountPath: String
        switch provider {
        case .codex: accountPath = ".codex"
        case .claudeCode: accountPath = ".claude"
        case .fx: accountPath = ".fx"
        case .grokBuild: accountPath = ".grok"
        case .muse: accountPath = ".config/muse"
        case .antigravity: accountPath = ".gemini/antigravity-cli"
        default: throw HarnessSetupError("Unsupported restricted harness storage.")
        }
        let destination = try WorkspaceMailbox(workspace: workspace, path: ".noodle/home/" + accountPath, create: true)
        let runtime = try WorkspaceMailbox(workspace: AgentStorageLayout(workspace: workspace).package, path: "runtime")
        func seed(_ data: Data, name: String) throws {
            let stamp = "auth-seed-\(provider.rawValue)-\(name).sha256"
            let fingerprint = Data(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().utf8)
            // Preserve refreshed bot credentials while the source login is unchanged.
            // A new shared sign-in deliberately replaces the bot's older login.
            if destination.contains(name), (try? runtime.read(stamp, limit: 128)) == fingerprint { return }
            try destination.writeData(data, named: name)
            try runtime.writeData(fingerprint, named: stamp)
        }
        func sourceData(_ name: String) throws -> Data? {
            let source = try WorkspaceMailbox(workspace: loginHome, path: accountPath)
            return source.contains(name) ? try source.read(name, limit: 1_048_576) : nil
        }
        switch provider {
        case .claudeCode:
            // Noodle's sign-in uses the standard Claude.ai account. The native
            // CLI prefers this exact Keychain item, with a file fallback. Copy
            // only that OAuth login, never other integrations in the payload.
            guard let data = try secret("Claude Code-credentials", NSUserName()) ?? sourceData(".credentials.json"),
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let oauth = payload["claudeAiOauth"] as? [String: Any],
                  let token = oauth["accessToken"] as? String, !token.isEmpty else { throw missing(provider) }
            try seed(JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth], options: [.sortedKeys]),
                     name: ".credentials.json")
        case .codex, .grokBuild:
            guard let data = try sourceData("auth.json") else { throw missing(provider) }
            try seed(data, name: "auth.json")
            if provider == .codex, !destination.contains("config.toml") {
                try destination.writeData(Data("cli_auth_credentials_store = \"file\"\n".utf8), named: "config.toml")
            }
        case .fx:
            let settings = try sourceData("settings.json").flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            // Only provider/model selection is carried across, never executable configuration.
            var selected = settings.filter { ["provider", "credential_source", "models", "effort", "fast_mode"].contains($0.key) }
            selected["auto_upgrade"] = false
            switch settings["provider"] as? String ?? "gateway" {
            case "codex", "chatgpt":
                guard let data = try sourceData("chatgpt-auth.json") else { throw missing(provider) }
                try seed(data, name: "chatgpt-auth.json")
            case "grok":
                guard let data = try sourceData("grok-auth.json") else { throw missing(provider) }
                try seed(data, name: "grok-auth.json")
            default:
                if settings["credential_source"] as? String == "stored_key" {
                    guard let data = try sourceData("api-key") ?? secret("FX_AI_GATEWAY_API_KEY", NSUserName()) else { throw missing(provider) }
                    try seed(data, name: "api-key")
                    selected["credential_source"] = "ai_gateway_api_key"
                } else {
                    guard let data = try sourceData("auth.json") ?? secret("FX_OAUTH_SESSION_V1", NSUserName()) else { throw missing(provider) }
                    try seed(data, name: "auth.json")
                }
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
            try seed(JSONSerialization.data(withJSONObject: auth, options: [.sortedKeys]), name: "auth.json")
        case .antigravity:
            // The CLI keeps its login in this Keychain item, or in this file when the
            // Keychain is out of reach, as it is for a profile and inside the sandbox.
            guard let data = try secret("gemini", "antigravity").flatMap(AntigravityProtocol.fileLogin)
                    ?? sourceData("antigravity-oauth-token") else { throw missing(provider) }
            try seed(data, name: "antigravity-oauth-token")
        default: break
        }
    }

    private static func missing(_ provider: HarnessProvider) -> HarnessSetupError {
        HarnessSetupError("The \(provider.displayName) login is unavailable for this bot's private storage. Sign in to the harness, then retry startup.")
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
