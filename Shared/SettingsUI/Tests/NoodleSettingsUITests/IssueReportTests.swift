import Foundation
import Testing
@testable import NoodleSettingsUI

struct IssueReportTests {
    @Test func bugReportOpensTheBugFormWithTheAreaChosen() throws {
        let url = IssueReport.url(.bug, area: "Incubator / Pion")
        #expect(url.absoluteString
            == "https://github.com/pdparchitect/noodle/issues/new?template=bug_report.yml&area=Incubator%20/%20Pion")
    }

    @Test func featureRequestOpensTheFeatureForm() throws {
        let items = try #require(URLComponents(url: IssueReport.url(.feature, area: "Noodle Browser"),
                                               resolvingAgainstBaseURL: false)?.queryItems)
        #expect(items == [URLQueryItem(name: "template", value: "feature_request.yml"),
                          URLQueryItem(name: "area", value: "Noodle Browser")])
    }

    /// Every area an app passes must be an option in both issue forms, or GitHub leaves the field unset.
    @Test(arguments: ["bug_report.yml", "feature_request.yml"])
    func everyAppAreaIsAFormOption(form: String) throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../../.github/ISSUE_TEMPLATE/\(form)").standardized
        let text = try String(contentsOf: root, encoding: .utf8)
        for area in ["Noodle", "Noodle Browser", "Noodle Computer", "Noodle Applet", "Noodle Mobile", "Incubator / Pion"] {
            #expect(text.contains("        - \(area)\n"), "\(form) lacks \(area)")
        }
    }
}
