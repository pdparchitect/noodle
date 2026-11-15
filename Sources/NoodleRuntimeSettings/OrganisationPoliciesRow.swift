import NoodleCore
import SwiftUI

/// One row in General on a Mac whose organisation set policies with a configuration profile. The policies
/// already hold on the controls they cover; the row only opens the list of them.
public struct OrganisationPoliciesSection: View {
    @State private var showsPolicies = false

    public init() {}

    public var body: some View {
        if OrganisationStatus.shared.isManaged {
            Section {
                LabeledContent(Organisation.managedText) {
                    Button("Show Policies") { showsPolicies.toggle() }
                        .popover(isPresented: $showsPolicies, arrowEdge: .bottom) { OrganisationPoliciesList() }
                }
            }
        }
    }
}

/// The policies in force, by name and value, with where to read about the enterprise feature.
private struct OrganisationPoliciesList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Policies").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(OrganisationStatus.shared.policy.rules, id: \.self) { rule in
                    GridRow {
                        Text(rule.title)
                        Text(rule.value).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            Link("Enterprise feature", destination: Organisation.enterpriseURL).font(.caption)
        }
        .padding(20)
        .frame(width: 380, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
