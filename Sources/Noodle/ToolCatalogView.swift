import AppKit
import SwiftUI
import NoodleCore

/// Protocol-independent catalogue. Setup routing is kept in ToolCreationSheet.
struct ToolCatalogView: View {
    let onSelect: (ToolDefinition) -> Void
    let onCustomMCP: () -> Void
    let onCancel: () -> Void
    var error: String? = nil
    @State private var search = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Text("New Tool").font(.headline)
                Spacer()
                // Balance the title without adding another focusable control.
                Text("Cancel").hidden().accessibilityHidden(true)
            }.padding(16)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                TextField("Search tools", text: $search)
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                Text("Choose a service to add it and sign in. You can customize it afterward.")
                    .font(.caption).foregroundStyle(.secondary)
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(ToolCatalog.matching(search)) { tool in
                            Button { onSelect(tool) } label: {
                                HStack(spacing: 12) {
                                    ToolCatalogIcon(tool: tool, size: 32)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(tool.name).foregroundStyle(.primary)
                                        Text(tool.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    Text(tool.kind.rawValue).font(.caption2).foregroundStyle(.secondary)
                                    Image(systemName: "plus.circle.fill").foregroundStyle(.blue)
                                }.padding(9).contentShape(Rectangle())
                            }.buttonStyle(.plain).help("Add \(tool.name) and sign in")
                        }
                        if ToolCatalog.matching(search).isEmpty {
                            Text("No matching tools. You can add a custom MCP below.")
                                .font(.caption).foregroundStyle(.secondary).padding()
                        }
                    }
                }.frame(height: 310)
                Divider()
                HStack {
                    Button("Custom MCP…", action: onCustomMCP)
                    Spacer()
                    Text("Connect your own MCP server")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(16)
        }.frame(width: 480)
    }
}

/// One dispatch boundary per supported tool type; MCP owns its form and storage.
struct ToolCreationSheet: View {
    let controller: MCPController
    var onAdded: (UUID) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var customMCP = false
    @State private var error: String?
    @State private var adding = false

    var body: some View {
        Group {
            if customMCP {
                MCPEditor(controller: controller, onBack: { customMCP = false }, onSaved: { onAdded($0.id) })
            } else {
                ToolCatalogView(onSelect: add, onCustomMCP: { customMCP = true },
                                onCancel: { dismiss() }, error: error).disabled(adding)
            }
        }
    }

    private func add(_ tool: ToolDefinition) {
        guard !adding else { return }
        adding = true
        do {
            switch tool.configuration {
            case .mcp(let configuration):
                let connection = try controller.addPreset(tool, configuration: configuration)
                onAdded(connection.id)
                dismiss()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    controller.connect(connection)
                }
            }
        } catch {
            self.error = error.localizedDescription
            adding = false
        }
    }
}

struct ToolCatalogIcon: View {
    let tool: ToolDefinition
    let size: CGFloat

    static func image(for tool: ToolDefinition) -> NSImage? {
        guard let url = Bundle.main.url(forResource: tool.iconName, withExtension: "icon", subdirectory: "ToolIcons") else { return nil }
        return NSImage(contentsOf: url)
    }

    var body: some View {
        Group {
            if let image = Self.image(for: tool) {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Text(String(tool.name.prefix(1))).font(.system(size: size * 0.55, weight: .semibold))
                    .frame(width: size, height: size)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: size * 0.22))
            }
        }.frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22))
            .accessibilityHidden(true)
    }
}
