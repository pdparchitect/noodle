import NoodleCore
@testable import PionCore
import XCTest

final class PionCatalogueTests: XCTestCase {
    func testPionOffersItsSecurityToolsAndOnlyTheNoodlePresetsThatHelpAnInvestigation() {
        let ids = PionCatalogue.entries.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "an entry is listed twice")
        for security in ["virustotal", "shodan", "okta", "entra", "defender", "crowdstrike", "sentinelone", "splunk", "elastic", "sentinel",
                         "cloudflare-security", "wiz", "github-security", "abuseipdb", "urlscan", "greynoise", "otx", "haveibeenpwned",
                         "aws", "google-cloud", "google-workspace", "grafana-cloud", "grafana-server"] {
            XCTAssertTrue(ids.contains(security), security)
        }
        for kept in ["atlassian", "linear", "notion", "axiom", "datadog", "sentry", "semgrep", "perplexity"] {
            XCTAssertTrue(ids.contains(kept), kept)
        }
        for dropped in ["canva", "stripe", "calendly", "gmail", "klaviyo", "otter", "grafana"] {
            XCTAssertFalse(ids.contains(dropped), dropped)
        }
        let noodle = Set(ToolCatalog.noodle.map(\.id))
        XCTAssertTrue(PionCatalogue.keptFromNoodle.isSubset(of: noodle),
                      "kept presets Noodle no longer has: \(PionCatalogue.keptFromNoodle.subtracting(noodle).sorted())")
        XCTAssertTrue(PionCatalogue.entries.allSatisfy { $0.adapter == nil || PionAdapters.all[$0.adapter!] != nil },
                      "an entry names an adapter Pion does not have")
    }

    /// Each of Pion's own services asks for a key or account, so each says how to get one, as Markdown the form can show.
    func testEveryPionServiceSaysHowToSetItUp() {
        let own = PionCatalogue.entries.filter { $0.adapter != nil }
        XCTAssertFalse(own.isEmpty)
        for tool in own {
            XCTAssertTrue(tool.needsSetUp, tool.id)
            XCTAssertGreaterThanOrEqual(tool.setup.count, 2, "\(tool.id) has no setup steps")
            for step in tool.setup {
                XCTAssertNoThrow(try AttributedString(markdown: step, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)), tool.id)
                XCTAssertFalse(step.contains("  "), "\(tool.id): \(step)")
            }
        }
    }
}
