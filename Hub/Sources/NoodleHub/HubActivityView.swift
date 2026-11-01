import HubCore
import SwiftUI

/// Who changed the Hub's users and devices, and who tried to and was refused, newest first.
struct HubActivityView: View {
    static let windowID = "activity"

    let log: HubActivityLog
    let access: HubAccess
    @State private var person: UUID?

    var body: some View {
        let entries = Array(log.entries(about: person).reversed())
        Group {
            if entries.isEmpty {
                ContentUnavailableView("No Logs", systemImage: "list.bullet.rectangle")
            } else {
                Table(entries) {
                    TableColumn("Date") { entry in
                        Text(entry.date, format: .dateTime.year().month().day().hour().minute())
                    }
                    .width(min: 150, ideal: 170, max: 200)
                    TableColumn("Who") { entry in
                        Text(entry.who)
                    }
                    .width(min: 120, ideal: 200)
                    TableColumn("What") { entry in
                        if let refusal = entry.refusal {
                            Label {
                                Text("\(entry.what): \(refusal)")
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            }
                            .help(refusal)
                        } else {
                            Text(entry.what)
                        }
                    }
                }
                .font(.subheadline.monospaced())
            }
        }
        .frame(minWidth: 640, minHeight: 360)
        .toolbar {
            ToolbarItem {
                Picker("Person", selection: $person) {
                    Text("Everyone").tag(UUID?.none)
                    ForEach(access.users) { Text($0.name).tag(Optional($0.id)) }
                }
                .pickerStyle(.menu)
                .padding(.horizontal, 6)
                .help("Show what concerns one person")
            }
        }
    }
}
