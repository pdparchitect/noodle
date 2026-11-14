import NoodleCore
import PionCore

/// The services Pion offers in Settings › Tools › Add Tools: Noodle's presets as they are, and Pion's own
/// security services, which its adapters answer.
enum PionTools {
    static let catalogue: [ToolDefinition] = ToolCatalog.noodle + [VirusTotal.preset, Shodan.preset, Okta.preset, Entra.preset, Defender.preset,
                                                         CrowdStrike.preset, SentinelOne.preset,
                                                         Splunk.preset, Elastic.preset, Sentinel.preset]
}
