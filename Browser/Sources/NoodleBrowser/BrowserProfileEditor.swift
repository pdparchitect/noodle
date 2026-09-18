import BrowserBridge
import BrowserCore
import NoodleWallpaper
import SwiftUI

struct BrowserProfileEditor: View {
    let presentation: BrowserPresentation
    let profile: BrowserProfile?
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var description: String
    @State private var icon: BrowserIconAppearance
    @State private var background: ConversationBackground
    @State private var backgroundFile: PreparedBackgroundFile?
    @State private var choosingBackground = false
    @State private var failure: String?

    init(presentation: BrowserPresentation, profile: BrowserProfile? = nil) {
        self.presentation = presentation; self.profile = profile
        _name = State(initialValue: profile?.name ?? presentation.library.nextBrowserName)
        _description = State(initialValue: profile?.description ?? "")
        _icon = State(initialValue: .init(symbol: profile?.symbol ?? "globe",
            colour: profile?.colour ?? presentation.library.profiles.count % 6, image: profile?.iconImage))
        _background = State(initialValue: profile?.background ?? .init())
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).foregroundStyle(.blue)
                Spacer()
                Text(profile == nil ? "New Browser" : "Edit Browser").font(.headline)
                Spacer()
                Button(profile == nil ? "Create" : "Save", action: save).keyboardShortcut(.defaultAction).foregroundStyle(.blue)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 120 ||
                        description.trimmingCharacters(in: .whitespacesAndNewlines).count > RemoteBrowser.maximumDescriptionLength)
            }.buttonStyle(.plain).padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 14) {
                    BrowserIconButton(appearance: $icon, symbol: "globe")
                    TextField("Browser name", text: $name).textFieldStyle(.roundedBorder).lineLimit(1)
                        .accessibilityIdentifier("browser.profile.name")
                }
                TextField("Description", text: $description, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...3)
                    .help("Tells assigned bots what this browser is for")
                    .accessibilityIdentifier("browser.profile.description")
                Button { choosingBackground = true } label: {
                    HStack {
                        Label("Background", systemImage: "photo")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }.padding(12).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain)
                    .sheet(isPresented: $choosingBackground) {
                        BrowserBackgroundSheet(background: background,
                            imageURL: profile.flatMap { presentation.library.backgroundURL(for: $0) }, file: backgroundFile) { selected, file in
                                background = selected; backgroundFile = file
                            }
                    }
                if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
            }.padding(24)
        }.frame(width: 480).controlSize(.regular).preferredColorScheme(.dark).noodleSheetSizing()
    }
    private func save() {
        do {
            let saved: BrowserProfile
            if let profile {
                var current = try presentation.library.profile(profile.id)
                current.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                current.description = description
                current.symbol = icon.iconSymbol ?? "globe"; current.colour = icon.iconColour
                current.iconImage = icon.iconImage; current.background = background
                try presentation.library.update(current, backgroundFile: backgroundFile)
                saved = current
            } else {
                saved = try presentation.library.create(name: name, description: description, symbol: icon.iconSymbol ?? "globe", colour: icon.iconColour, iconImage: icon.iconImage,
                    background: background, backgroundFile: backgroundFile)
            }
            presentation.selection = saved.id
            dismiss()
        } catch { failure = error.localizedDescription }
    }
}
