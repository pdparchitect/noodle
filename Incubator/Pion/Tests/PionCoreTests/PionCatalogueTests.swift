import NoodleCore
@testable import PionCore
import XCTest

final class PionCatalogueTests: XCTestCase {
    func testPionOffersItsSecurityToolsAndOnlyTheNoodlePresetsThatHelpAnInvestigation() {
        let ids = PionCatalogue.entries.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "an entry is listed twice")
        XCTAssertTrue(ids.allSatisfy { UUID(uuidString: $0) != nil }, "an entry is not identified by a UUID")
        let names = Set(PionCatalogue.entries.map(\.name))
        for security in ["VirusTotal", "Shodan", "Okta Audit", "Okta Containment", "Microsoft Entra ID Audit", "Microsoft Entra ID Containment", "Microsoft Defender XDR Audit", "Microsoft Defender XDR Containment", "CrowdStrike Falcon Audit", "CrowdStrike Falcon Containment", "SentinelOne",
                         "Splunk", "Elastic", "Microsoft Sentinel", "Cloudflare Security", "Cloudflare Radar", "Wiz", "AbuseIPDB", "GreyNoise", "CrowdSec CTI", "NVD", "crt.sh", "cve.now", "AWS Audit", "AWS Containment", "Microsoft Azure Audit", "Microsoft Azure Containment",
                         "Google Cloud Audit", "Google Workspace Audit", "Google Workspace Containment", "Grafana Cloud", "Self-Hosted Grafana", "Sentry", "Self-Hosted Sentry"] {
            XCTAssertTrue(names.contains(security), security)
        }
        // Noodle's own entries, by their icons' names.
        let fromNoodle = Set(PionCatalogue.entries.filter { entry in ToolCatalog.noodle.contains { $0.id == entry.id } }.map(\.iconName))
        for kept in ["atlassian", "linear", "notion", "axiom", "datadog", "grafana", "sentry", "semgrep", "perplexity"] {
            XCTAssertTrue(fromNoodle.contains(kept), kept)
        }
        for dropped in ["canva", "stripe", "calendly", "gmail", "klaviyo", "otter"] {
            XCTAssertFalse(fromNoodle.contains(dropped), dropped)
        }
        let noodle = Set(ToolCatalog.noodle.map(\.id))
        XCTAssertTrue(PionCatalogue.keptFromNoodle.isSubset(of: noodle),
                      "kept presets Noodle no longer has: \(PionCatalogue.keptFromNoodle.subtracting(noodle).sorted())")
        XCTAssertTrue(PionCatalogue.entries.allSatisfy { $0.adapter == nil || PionAdapters.all[$0.adapter!] != nil },
                      "an entry names an adapter Pion does not have")
    }

    /// Each of Pion's own services that asks for a key or account says how to get one, as Markdown the form can show;
    /// one that asks for nothing, as NVD, has nothing to say.
    func testEveryPionServiceSaysHowToSetItUp() {
        let own = PionCatalogue.entries.filter { $0.adapter != nil }
        XCTAssertFalse(own.isEmpty)
        for tool in own {
            guard tool.needsSetUp else { XCTAssertTrue(tool.setup.isEmpty, tool.id); continue }
            XCTAssertGreaterThanOrEqual(tool.setup.count, 2, "\(tool.id) has no setup steps")
            for step in tool.setup {
                XCTAssertNoThrow(try AttributedString(markdown: step, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)), tool.id)
                XCTAssertFalse(step.contains("  "), "\(tool.id): \(step)")
            }
        }
    }

    /// Each of Pion's services shows its own icon, bundled from the shared folder, not a letter.
    func testEveryPionServiceHasAnIcon() {
        let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../Support/ToolIcons").standardizedFileURL
        for tool in PionCatalogue.entries {
            XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent(tool.iconName + ".icon").path),
                          "\(tool.name) has no icon \(tool.iconName).icon")
        }
    }
}
