import AppKit
import NoodleCore
import SwiftUI

/// Folders outside the workspace that the bot may use. Only paths are kept:
/// Agent Host grants them to the bot's sandbox, the app never opens them.
struct BotFolderPicker: View {
    @Binding var folders: [AgentFolder]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Folders").font(.caption.weight(.semibold))
                Spacer()
                Button(action: add) { Label("Add Folders", systemImage: "plus") }
            }
            ScrollView {
                if folders.isEmpty {
                    Button(action: add) {
                        VStack(spacing: 10) {
                            Image(systemName: "folder.badge.plus").font(.largeTitle)
                            Text("Add folders to this bot")
                        }.foregroundStyle(.secondary).frame(maxWidth: .infinity)
                            .padding(.vertical, 32).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Add folders to this bot")
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach($folders) { $folder in
                            BotFolderRow(folder: $folder) { folders.removeAll { $0.path == folder.path } }
                            if folder.path != folders.last?.path { Divider().padding(.leading, 44) }
                        }
                    }.padding(.vertical, 4)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 140, maxHeight: 280)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func add() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let path = url.standardizedFileURL.path
            if !folders.contains(where: { $0.path == path }) { folders.append(AgentFolder(path: path)) }
        }
    }
}

private struct BotFolderRow: View {
    @Binding var folder: AgentFolder
    let remove: () -> Void
    @State private var showingOptions = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.fill").font(.system(size: 18)).foregroundStyle(.blue).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(folder.name).lineLimit(1)
                    if !folder.writable {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary)
                            .help("Read Only").accessibilityLabel("Read Only")
                    }
                }
                Text((folder.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Button { showingOptions = true } label: {
                Image(systemName: "ellipsis.circle.fill").symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color(nsColor: .darkGray))
            }.buttonStyle(.plain).help("Access and Description")
                .accessibilityLabel("Access and description of \(folder.name)")
                .popover(isPresented: $showingOptions, arrowEdge: .bottom) { BotFolderOptions(folder: $folder) }
            Button(action: remove) {
                Image(systemName: "minus.circle.fill").symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color(nsColor: .darkGray))
            }.buttonStyle(.plain).help("Remove \(folder.name) from bot")
                .accessibilityLabel("Remove \(folder.name) from bot")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .help([folder.path, folder.description].compactMap { $0 }.joined(separator: "\n"))
    }
}

struct BotFolderOptions: View {
    @Binding var folder: AgentFolder

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Access").font(.caption.weight(.semibold))
                Picker("Access", selection: $folder.writable) {
                    Text("Read & Write").tag(true)
                    Text("Read Only").tag(false)
                }.pickerStyle(.segmented).labelsHidden()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Description").font(.caption.weight(.semibold))
                TextField("Describe what this folder is for…", text: Binding(
                    get: { folder.description ?? "" },
                    set: { folder.description = $0.isEmpty ? nil : String($0.prefix(AgentFolder.descriptionLimit)) }
                ), axis: .vertical)
                    .textFieldStyle(.roundedBorder).lineLimit(3...5)
                    .accessibilityLabel("Description of \(folder.name)")
            }
        }.padding(16).frame(width: 300)
    }
}
