public enum CodexLaunch {
    /// Explicitly override inherited config for each Noodle runtime and probe.
    public static func appServerArguments(appsEnabled: Bool = false) -> [String] {
        // Codex has no environment switch for its usage reports; see HarnessProvider.reportingOffEnvironment.
        ["app-server", "-c", "analytics.enabled=false", appsEnabled ? "--enable" : "--disable", "apps"]
    }
}
