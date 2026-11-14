import NoodleCore
@testable import PionCore
import XCTest

final class PionCatalogueTests: XCTestCase {
    func testPionOffersItsSecurityToolsAndOnlyTheNoodlePresetsThatHelpAnInvestigation() {
        let ids = PionCatalogue.entries.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "an entry is listed twice")
        for security in ["virustotal", "shodan", "okta", "entra", "defender", "crowdstrike", "sentinelone", "splunk", "elastic", "sentinel",
                         "cloudflare-security", "wiz", "github-security", "abuseipdb", "urlscan", "greynoise", "otx", "haveibeenpwned",
                         "aws", "google-cloud", "google-workspace"] {
            XCTAssertTrue(ids.contains(security), security)
        }
        for kept in ["atlassian", "linear", "notion", "axiom", "datadog", "sentry", "semgrep", "perplexity"] {
            XCTAssertTrue(ids.contains(kept), kept)
        }
        for dropped in ["canva", "stripe", "calendly", "gmail", "klaviyo", "otter"] {
            XCTAssertFalse(ids.contains(dropped), dropped)
        }
        let noodle = Set(ToolCatalog.noodle.map(\.id))
        XCTAssertTrue(PionCatalogue.keptFromNoodle.isSubset(of: noodle),
                      "kept presets Noodle no longer has: \(PionCatalogue.keptFromNoodle.subtracting(noodle).sorted())")
        XCTAssertTrue(PionCatalogue.entries.allSatisfy { $0.adapter == nil || PionAdapters.all[$0.adapter!] != nil },
                      "an entry names an adapter Pion does not have")
    }
}
