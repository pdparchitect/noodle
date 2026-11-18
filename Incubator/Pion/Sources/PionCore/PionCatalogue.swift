import NoodleCore

/// The services Pion offers in Settings › Tools › Add Tools: its own security services, which its adapters answer,
/// and the few of Noodle's presets that help an investigation.
public enum PionCatalogue {
    /// Noodle's presets kept: tickets and notes, observability, code security and search, and web research. Grafana and
    /// Sentry are Pion's own, read-only, for their own services and self-hosted ones.
    static let keptFromNoodle: Set<String> = [
        "e1cce3a2-3e55-4949-ad25-950a70fe3599", // atlassian
        "ec956078-71a2-4599-83d6-b9e5ef43ad9c", // linear
        "21bd7ea0-d479-4f46-a705-bd4046a3dfec", // notion
        "e0a407a2-a551-490a-a1b2-eed96f1190a7", // axiom
        "7f412e92-4f67-44ff-87c1-3831ebd975bb", // datadog
        "c70b0318-fb98-4d9e-9c20-1708555045e1", // honeycomb
        "2d121438-4335-4ac7-9705-b9a87b3c2312", // semgrep
        "c0a4eff4-ac47-4b92-8fa2-209f9f304812", // socket
        "c754d63b-ae5d-4ef5-933e-a9ceae0a5465", // sourcegraph
        "c9d74b1c-1e1c-4da2-91c7-0e7b625c6f51", // cloudflare
        "c9b4449d-5c40-4e71-8b3f-7d65f31f3f75", // exa
        "e2957e02-d584-4703-90f2-3d8528604a2c", // perplexity
        "05a1388d-8b94-493d-9bdb-21c0dbdee9dd", // tavily
        "13c81353-d291-448c-83a4-0cc71bd67b05", // parallelai-search
    ]

    public static let entries: [ToolDefinition] = [
        VirusTotal.preset, Shodan.preset, Okta.preset, Entra.preset, Defender.preset, CrowdStrike.preset, SentinelOne.preset,
        Splunk.preset, Elastic.preset, Sentinel.preset, Cloudflare.preset, Wiz.preset, GitHub.preset, AbuseIPDB.preset,
        URLScan.preset, GreyNoise.preset, OTX.preset, HaveIBeenPwned.preset, AWS.preset, GoogleCloud.preset, GoogleWorkspace.preset,
        Proofpoint.preset, SumoLogic.preset, Tenable.preset, Censys.preset, Grafana.cloud, Grafana.server, Sentry.cloud, Sentry.server,
    ] + ToolCatalog.noodle.filter { keptFromNoodle.contains($0.id) }
}
