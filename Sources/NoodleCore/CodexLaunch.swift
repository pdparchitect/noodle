public enum CodexLaunch {
    /// Explicitly override inherited config for each Noodle runtime and probe.
    public static func appServerArguments(appsEnabled: Bool = false) -> [String] {
        ["app-server", appsEnabled ? "--enable" : "--disable", "apps"]
    }
}
