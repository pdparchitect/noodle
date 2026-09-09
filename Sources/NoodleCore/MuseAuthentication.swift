import Foundation

/// Read only by the Agent Host. No credentials or account details leave this check.
/// “Authenticated” means a saved login, not a verified remote account or credit balance.
public enum MuseAuthentication {
    public static func inspect(home: URL, environment: [String: String]) -> HarnessAuthenticationStatus {
        if let key = environment["META_API_KEY"], !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .authenticated
        }
        let config: URL
        if let path = environment["XDG_CONFIG_HOME"], path.hasPrefix("/") {
            config = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            config = home.appendingPathComponent(".config", isDirectory: true)
        }
        let path = config.appendingPathComponent("muse/auth.json").path
        // Bound the read, reject special files, and do not follow credential-file symlinks.
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return errno == ENOENT ? .unauthenticated : .managedExternally }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        let limit = 1_048_576
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size >= 0, info.st_size <= limit else { return .managedExternally }
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else { return .managedExternally }
        return status(data: data)
    }

    static func status(data: Data) -> HarnessAuthenticationStatus {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .managedExternally }
        guard let providersValue = root["providers"] else { return root.isEmpty ? .unauthenticated : .managedExternally }
        guard let providers = providersValue as? [String: Any] else { return .managedExternally }
        guard let slot = providers["meta"] else { return .unauthenticated }
        guard let meta = slot as? [String: Any], let mechanism = meta["mechanism"] as? String,
              ["oauth", "api_key"].contains(mechanism) else { return .managedExternally }
        // Muse's current native CLI stores secrets in Keychain; auth.json keeps this marker.
        // Do not query Keychain: that could prompt or require a new application access grant.
        if let storage = meta["storage"] as? String {
            if storage == "keychain" { return .authenticated }
            guard storage == "file" else { return .managedExternally }
        }
        func present(_ key: String) -> Bool {
            guard let value = meta[key] as? String else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if mechanism == "api_key", present("api_key") { return .authenticated }
        // An expired access token may still be refreshed by Muse. Never refresh it here.
        if mechanism == "oauth", present("access_token") || present("refresh_token") { return .authenticated }
        return .managedExternally
    }
}
