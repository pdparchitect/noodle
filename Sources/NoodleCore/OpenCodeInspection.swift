import Foundation
import ProductIdentity

public enum OpenCodeInspection {
    /// `managed` is the copy Noodle installed, already verified by the caller,
    /// and is used when the user has no installation of their own, or chose it over theirs. `loginHome`
    /// holds the login, laid out like `home`, which holds the installation.
    public static func inspect(home: URL, loginHome: URL? = nil, application: URL, managed: URL? = nil, prefersManaged: Bool = false) throws -> OpenCodeInspectionResult {
        let path = home.appendingPathComponent(".opencode/bin/opencode").path
        guard !(prefersManaged && managed != nil), FileManager.default.isExecutableFile(atPath: path) else {
            guard let managed else { return .init(executablePath: nil, authenticated: false, models: []) }
            return try inspect(executable: managed, installationPath: managed.path, home: home, loginHome: loginHome, application: application)
        }
        let executable = try OpenCodeExecutableTrust.executable(at: path, home: home)
        return try inspect(executable: executable, installationPath: path, home: home, loginHome: loginHome, application: application)
    }

    static func inspect(executable: URL, installationPath: String, home: URL, loginHome: URL? = nil,
                        application: URL) throws -> OpenCodeInspectionResult {
        let package = FileManager.default.temporaryDirectory.appendingPathComponent("noodle-opencode-probe-\(UUID())").resolvingSymlinksInPath()
        let layout = AgentStorageLayout(package: package)
        try layout.create()
        defer { try? FileManager.default.removeItem(at: package) }
        try OpenCodeStorage.prepareDirectories(workspace: layout.workspace)
        let environment = OpenCodeStorage.environment(workspace: layout.workspace).merging(["PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "OPENCODE_DISABLE_PROJECT_CONFIG": "true"]) { _, new in new }
        let profile = try RestrictedAgentSandbox.profile(provider: .openCode, workspace: layout.workspace,
            repository: package, home: home, executable: executable, application: application, temporary: layout.workspace)
        let version = try OpenCodeCommand.run(executable, arguments: ["--version"], workspace: layout.workspace,
            environment: environment, profile: profile, timeout: 8)
        guard let parsed = HarnessVersion.parseOutput(String(decoding: version, as: UTF8.self)),
              OpenCodeProtocol.supportsVersion(parsed.text) else {
            throw HarnessSetupError("\(ProductIdentity.current.name) requires OpenCode v2. Run the v2 installer in Terminal, then check again.")
        }
        let authenticated = try OpenCodeStorage.seed(workspace: layout.workspace, loginHome: loginHome ?? home,
            executable: executable, environment: environment, profile: profile)
        return .init(executablePath: installationPath, authenticated: authenticated,
            models: try prepareCatalogue(executable: executable, workspace: layout.workspace,
                environment: environment, profile: profile))
    }

    /// Warm the bot's own catalogue before ACP snapshots it on its first session.
    /// The native process owns fetching and caching; no global cache is imported.
    @discardableResult
    public static func prepareCatalogue(executable: URL, workspace: URL,
                                        environment: [String: String], profile: String) throws -> [HarnessModel] {
        let probe = try OpenCodeModelProbe(executable: executable,
            workspace: workspace, environment: environment, profile: profile)
        defer { probe.stop() }
        return try probe.models()
    }
}
