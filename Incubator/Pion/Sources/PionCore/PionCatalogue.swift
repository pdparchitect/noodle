import NoodleCore

/// The services Pion offers in Settings › Tools › Add Tools: its own security services, which its adapters answer,
/// and the few of Noodle's presets that help an investigation.
public enum PionCatalogue {
    /// Noodle's presets kept: tickets and notes, observability, code security and search, and web research.
    static let keptFromNoodle: Set<String> = [
        "atlassian", "linear", "notion",
        "axiom", "datadog", "grafana", "honeycomb", "sentry",
        "semgrep", "socket", "sourcegraph", "cloudflare",
        "exa", "perplexity", "tavily", "parallelai-search",
    ]

    public static let entries: [ToolDefinition] = [
        VirusTotal.preset, Shodan.preset, Okta.preset, Entra.preset, Defender.preset, CrowdStrike.preset, SentinelOne.preset,
        Splunk.preset, Elastic.preset, Sentinel.preset, Cloudflare.preset, Wiz.preset, GitHub.preset, AbuseIPDB.preset,
        URLScan.preset, GreyNoise.preset, OTX.preset, HaveIBeenPwned.preset, AWS.preset, GoogleCloud.preset, GoogleWorkspace.preset,
        Proofpoint.preset, SumoLogic.preset, Tenable.preset, Censys.preset,
    ] + ToolCatalog.noodle.filter { keptFromNoodle.contains($0.id) }
}
