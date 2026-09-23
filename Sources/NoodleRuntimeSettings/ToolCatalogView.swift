import AppKit
import SwiftUI
import NoodleCore

/// Protocol-independent catalogue. Setup routing is kept in ToolCreationSheet.
public struct ToolCatalogView: View {
    let onSelect: (ToolDefinition) -> Void
    let onCustomMCP: () -> Void
    let onCancel: () -> Void
    var error: String? = nil
    @State private var search = ""

    public var body: some View {
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
                                    ToolMaturityBadge(maturity: tool.maturity)
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

public struct ToolMaturityBadge: View {
    let maturity: ToolMaturity
    public var body: some View {
        if let badge = maturity.badge {
            Text(badge).font(.caption2).foregroundStyle(.orange)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.orange.opacity(0.12), in: Capsule())
        }
    }
}

public struct MCPConnectionMaturityBadge: View {
    let connection: MCPConnectionRecord
    public var body: some View {
        if let tool = ToolCatalog.definition(forMCPEndpoint: connection.endpoint) {
            ToolMaturityBadge(maturity: tool.maturity)
        }
    }

    public init(connection: MCPConnectionRecord) {
        self.connection = connection
    }
}

/// One dispatch boundary per supported tool type; MCP owns its form and storage.
public struct ToolCreationSheet: View {
    let controller: MCPController
    var onAdded: (UUID) -> Void = { _ in }
    private let onConnect: (MCPConnectionRecord) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var customMCP = false
    @State private var error: String?
    @State private var adding = false
    @State private var presetAttempts: [String: UUID] = [:]

    public init(controller: MCPController, onAdded: @escaping (UUID) -> Void = { _ in },
         onConnect: ((MCPConnectionRecord) -> Void)? = nil) {
        self.controller = controller; self.onAdded = onAdded
        self.onConnect = onConnect ?? controller.connect
    }

    public var body: some View {
        Group {
            if customMCP {
                MCPEditor(controller: controller, onBack: { customMCP = false }, onSaved: { onAdded($0.id) }, onConnect: onConnect)
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
                // Saving the account can precede a failed workspace refresh.
                // Retrying this preset must resume that account, even after
                // the user has tried another preset in the same sheet.
                let id = presetAttempts[tool.id] ?? UUID()
                presetAttempts[tool.id] = id
                let connection = try controller.addPreset(tool, configuration: configuration, connectionID: id)
                onAdded(connection.id)
                dismiss()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(250))
                    onConnect(connection)
                }
            }
        } catch {
            self.error = error.localizedDescription
            adding = false
        }
    }
}

public struct ToolCatalogIcon: View {
    let tool: ToolDefinition
    let size: CGFloat

    static func image(for tool: ToolDefinition) -> NSImage? {
        guard let url = Bundle.main.url(forResource: tool.iconName, withExtension: "icon", subdirectory: "ToolIcons") else { return nil }
        return NSImage(contentsOf: url)
    }

    public var body: some View {
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
