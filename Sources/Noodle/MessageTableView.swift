import AppKit
import SwiftUI
import NoodleCore
import HubLink

/// A Markdown table drawn as its own bubble, sortable in place and folded when long.
struct MessageTableView<Menu: View>: View {
    @Environment(NoodleStore.self) private var store
    let message: ChatMessage
    let table: MessageTable
    /// The message's context menu, given the table as currently shown.
    let menu: (MessageTable) -> Menu
    @State private var sort: MessageTableSort?
    @State private var hovering = false
    @State private var showingAll = false
    @State private var gridWidth: CGFloat?

    var body: some View {
        let shown = table.sorted(by: sort)
        // A table that fits hugs its columns; a wider one fills the bubble and scrolls inside it.
        // One measured view rather than ViewThatFits, which keeps both candidates for VoiceOver.
        content
            .frame(maxWidth: gridWidth, alignment: .leading)
            .overlay { menu(shown) }
        .overlay(alignment: .topTrailing) {
            if hovering { MessageTableActions(table: shown) { store.errorMessage = $0 }.padding(4) }
        }
        .onHover { hovering = $0 }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                MessageTableGrid(table: table, rowLimit: table.folds ? MessageTable.foldedRowCount : nil, sort: $sort)
                    // Its cells' text is the message's, to annotate with the shortcut like the rest of it.
                    .background(ConversationAnnotationText(message: message))
                    .onGeometryChange(for: CGFloat.self, of: \.size.width) { gridWidth = $0 }
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            if table.folds {
                Divider().opacity(0.6)
                Button { showingAll = true } label: {
                    Label("\(table.rows.count - MessageTable.foldedRowCount) more rows", systemImage: "tablecells")
                        .font(.system(size: 11.5, weight: .semibold))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showingAll, arrowEdge: .bottom) {
                    MessageTableReader(message: message, table: table, sort: $sort, close: { showingAll = false })
                        .environment(store)
                }
            }
        }
    }
}

struct MessageTableGrid: View {
    let table: MessageTable
    var rowLimit: Int?
    @Binding var sort: MessageTableSort?

    var body: some View {
        // Rows keep their identity while sorting, or selectable cells would hold stale text.
        let order = Array(table.rowOrder(by: sort).prefix(rowLimit ?? table.rows.count))
        Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
            GridRow {
                ForEach(table.header.indices, id: \.self) { column in
                    header(column)
                        .messageTableHeaderCell()
                }
            }
            ForEach(order, id: \.self) { row in
                Divider().opacity(0.6)
                GridRow {
                    ForEach(table.header.indices, id: \.self) { column in
                        MessageTableCellLayout(maxWidth: 260) {
                            Text(MessageMarkdownCache.render(table.rows[row][column]))
                                .font(.system(size: 12.5).monospacedDigit())
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .gridColumnAlignment(alignment(column).horizontal)
                        .textSelection(.enabled)
                    }
                }
            }
        }
        .fixedSize()
        .padding(.horizontal, 4)
        .messageTableHeaderBackground()
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
                Text(MessageMarkdownCache.render(table.header[column])).lineLimit(1)
                if !trailing { indicator(active) }
            }
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(active ? .primary : .secondary)
            .frame(maxWidth: 260, alignment: alignment(column))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .gridColumnAlignment(alignment(column).horizontal)
        .help("Sort by \(name)")
        .accessibilityLabel("Sort by \(name)")
        .accessibilityValue(active ? (sort?.ascending == true ? "Ascending" : "Descending") : "")
    }

    // Always laid out, so a column keeps its width when it becomes the sorted one.
    private func indicator(_ active: Bool) -> some View {
        Image(systemName: sort?.ascending == false ? "chevron.down" : "chevron.up")
            .font(.system(size: 8, weight: .bold))
            .opacity(active ? 1 : 0)
            .accessibilityHidden(true)
    }
}

struct MessageTableReader: View {
    @Environment(NoodleStore.self) private var store
    let message: ChatMessage
    let table: MessageTable
    @Binding var sort: MessageTableSort?
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Table").font(.headline)
                Text("\(table.rows.count) rows").foregroundStyle(.secondary)
                Spacer()
                MessageTableActions(table: table.sorted(by: sort)) { store.errorMessage = $0 }
                Button(action: close) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .help("Close")
                    .accessibilityLabel("Close")
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            Divider()
            ScrollView([.vertical, .horizontal]) {
                MessageTableGrid(table: table, sort: $sort)
                    .background(ConversationAnnotationText(message: message))
                    .padding(12)
            }
        }
        .foregroundStyle(Color.primary)
        .frame(width: min(600, (NSScreen.main?.visibleFrame.width ?? 800) - 80),
               height: min(540, (NSScreen.main?.visibleFrame.height ?? 700) - 100))
        .modifier(MessageReaderAnnotations(message: message))
    }
}
