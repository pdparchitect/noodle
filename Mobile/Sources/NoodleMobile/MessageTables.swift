import CoreTransferable
import HubLink
import SwiftUI
import UniformTypeIdentifiers

/// A table in a message: too wide for a phone's bubble, so a card that opens it in a sheet.
struct MessageTableCard: View {
    let table: MessageTable
    let foreground: Color
    let background: Color
    @State private var showing = false

    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "tablecells").font(.title3).foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(table.header.map(MessageTable.plainText).joined(separator: " · "))
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(table.rows.count == 1 ? "1 row" : "\(table.rows.count) rows")
                        .font(.footnote).foregroundStyle(foreground.opacity(0.7))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(foreground.opacity(0.5))
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: 280, alignment: .leading)
            .foregroundStyle(foreground)
            .tint(background == .accentColor ? foreground : .accentColor)
            .background(background, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Table")
        .accessibilityValue(table.rows.count == 1 ? "1 row" : "\(table.rows.count) rows")
        .accessibilityHint("Opens the table")
        .sheet(isPresented: $showing) { MessageTableSheet(table: table) }
    }
}

/// The whole table, sortable by tapping a column's header, to copy or share as CSV.
struct MessageTableSheet: View {
    let table: MessageTable
    @State private var sort: MessageTableSort?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView([.horizontal, .vertical]) {
                MessageTableGrid(table: table, sort: $sort).padding()
            }
            .navigationTitle("Table")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Copy as CSV", systemImage: "doc.on.doc") { UIPasteboard.general.string = table.sorted(by: sort).csv }
                        ShareLink(item: TableCSV(table: table.sorted(by: sort)), preview: SharePreview("Table.csv")) {
                            Label("Share CSV", systemImage: "square.and.arrow.up")
                        }
                    } label: {
                        Label("Table Actions", systemImage: "ellipsis")
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct MessageTableGrid: View {
    let table: MessageTable
    @Binding var sort: MessageTableSort?
    @State private var headerHeight: CGFloat = 0

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(table.header.indices, id: \.self) { column in
                    header(column)
                        .onGeometryChange(for: CGFloat.self, of: \.size.height) { headerHeight = max(headerHeight, $0) }
                }
            }
            // Rows keep their identity while sorting, so they move rather than change text.
            ForEach(table.rowOrder(by: sort), id: \.self) { row in
                Divider()
                GridRow {
                    ForEach(table.header.indices, id: \.self) { column in
                        Text(MessageText.markdown(table.rows[row][column]))
                            .font(.subheadline.monospacedDigit())
                            .frame(maxWidth: 240, alignment: alignment(column))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .gridColumnAlignment(alignment(column).horizontal)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .fixedSize()
        .background(alignment: .top) { Color.primary.opacity(0.06).frame(height: headerHeight) }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func alignment(_ column: Int) -> Alignment {
        switch table.alignment(column) {
        case .trailing: .trailing
        case .center: .center
        case .leading, .automatic: .leading
        }
    }

    private func header(_ column: Int) -> some View {
        let active = sort?.column == column
        let name = MessageTable.plainText(table.header[column])
        let trailing = table.alignment(column) == .trailing
        return Button {
            withAnimation(.snappy(duration: 0.2)) { sort = MessageTableSort.next(after: sort, column: column) }
        } label: {
            HStack(spacing: 3) {
                if trailing { indicator(active) }
                Text(name).lineLimit(1)
                if !trailing { indicator(active) }
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(active ? .primary : .secondary)
            .frame(maxWidth: 240, alignment: alignment(column))
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .gridColumnAlignment(alignment(column).horizontal)
        .accessibilityLabel("Sort by \(name)")
        .accessibilityValue(active ? (sort?.ascending == true ? "Ascending" : "Descending") : "")
    }

    // Always laid out, so a column keeps its width when it becomes the sorted one.
    private func indicator(_ active: Bool) -> some View {
        Image(systemName: sort?.ascending == false ? "chevron.down" : "chevron.up")
            .font(.system(size: 9, weight: .bold))
            .opacity(active ? 1 : 0)
            .accessibilityHidden(true)
    }
}

/// A table shared as a CSV file.
private struct TableCSV: Transferable {
    let table: MessageTable

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { Data($0.table.csv.utf8) }
            .suggestedFileName("Table.csv")
    }
}
