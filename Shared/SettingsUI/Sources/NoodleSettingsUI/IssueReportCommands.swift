import AppKit
import SwiftUI

/// The project's GitHub issue forms, opened with the reporting app already chosen in their Affected area
/// field. Each area is one of that field's options in .github/ISSUE_TEMPLATE, matched exactly or GitHub
/// leaves the field unset.
public enum IssueReport {
    public enum Kind: String, Sendable {
        case bug = "bug_report.yml"
        case feature = "feature_request.yml"
    }

    public static func url(_ kind: Kind, area: String) -> URL {
        var components = URLComponents(string: "https://github.com/pdparchitect/noodle/issues/new")!
        components.queryItems = [URLQueryItem(name: "template", value: kind.rawValue),
                                 URLQueryItem(name: "area", value: area)]
        return components.url!
    }
}

/// Help menu items that open a new bug report or feature request for the app naming `area`.
public struct IssueReportButtons: View {
    let area: String

    public init(area: String) {
        self.area = area
    }

    public var body: some View {
        Button("Report a Bug") { NSWorkspace.shared.open(IssueReport.url(.bug, area: area)) }
        Button("Request a Feature") { NSWorkspace.shared.open(IssueReport.url(.feature, area: area)) }
    }
}
