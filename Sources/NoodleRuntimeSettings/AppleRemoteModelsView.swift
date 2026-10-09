import NoodleCore
import NoodleRuntime
import SwiftUI

public struct AppleRemoteModelsView: View {
    let store: any BotSettingsHost
    @Environment(\.dismiss) private var dismiss
    @State private var accounts: [RemoteModelAccount] = []
    @State private var checkedSupport: Bool?
    @State private var checked = false
    @State private var error: String?
    @State private var form: AccountForm?
    @State private var modelForm: ModelForm?
    @State private var accountPendingRemoval: RemoteModelAccount?
    @State private var usageAccountID: UUID?
    @State private var editingAgent: AgentRecord?
    @State private var returnToAccountID: UUID?
    @State private var listHeight: CGFloat = 0
    private let accountStore: RemoteModelAccountStore?
    private let checkSupport: @MainActor () async throws -> Bool
    private let checkKey: @Sendable (RemoteProvider, String) async throws -> Void
    private let findModels: @Sendable (RemoteProvider, String) async throws -> [RemoteModelInfo]

    init(store: any BotSettingsHost, accountStore: RemoteModelAccountStore? = nil,
         checkSupport: @escaping @MainActor () async throws -> Bool = { try await AppleHostProbe.load().localModelsSupported == true },
         checkKey: @escaping @Sendable (RemoteProvider, String) async throws -> Void = { try await $0.checkKey($1) },
         findModels: @escaping @Sendable (RemoteProvider, String) async throws -> [RemoteModelInfo] = { try await $0.findModels(apiKey: $1) }) {
        self.store = store
        self.accountStore = accountStore
        self.checkSupport = checkSupport
        self.checkKey = checkKey
        self.findModels = findModels
    }

    private var storage: RemoteModelAccountStore { accountStore ?? .init(repository: store.repository.rootURL) }
    private var knownSupport: Bool? { checkedSupport ?? store.runtime.appleLocalModelsSupported }
    private var supported: Bool { knownSupport == true }
    private var checking: Bool { !checked && knownSupport == nil }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Remote Models").font(.title2.bold())
                    .padding(.horizontal, 24)

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        content
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: min(listHeight, 520))

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 24)
                }
            }
            .padding(.vertical, 24)

            Divider()
            HStack {
                Menu("Add Account") {
                    ForEach(RemoteProviders.all, id: \.id) { provider in
                        if provider.id == CustomProvider.id { Divider() }
                        Button("\(provider.displayName)…") { form = .add(provider) }
                    }
                }
                .fixedSize()
                .disabled(!supported)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(item: $form) { form in
            AccountFormView(form: form, checkKey: checkKey, findModels: findModels) { name, key, models, baseURL in
                try save(form, name: name, key: key, models: models, baseURL: baseURL)
            }
        }
        .sheet(item: $modelForm) { form in
            ModelFormView(form: form, suggestions: { await suggestions(for: form.account) }) { model in
                try storage.saveModel(model, replacing: form.model?.id, account: form.account.id)
                try changed()
                error = nil
            }
        }
        .sheet(item: $editingAgent, onDismiss: {
            if let id = returnToAccountID, accounts.contains(where: { $0.id == id }) { usageAccountID = id }
            returnToAccountID = nil
        }) { agent in
            store.botRuntimeEditor(agent)
                .noodleSheetSizing()
        }
        .alert("Remove Account?", isPresented: Binding(
            get: { accountPendingRemoval != nil },
            set: { if !$0 { accountPendingRemoval = nil } }
        ), presenting: accountPendingRemoval) { account in
            Button("Remove", role: .destructive) { remove(account) }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: { account in
            Text("“\(account.name)” and its API key will be removed from Noodle.")
        }
        .onAppear {
            do { try reload() } catch { self.error = error.localizedDescription }
        }
        .task {
            // Quietly: the server may simply not be running now.
            for account in accounts where account.provider?.findsModels == true { await refreshModels(account, quietly: true) }
        }
        .task {
            do {
                let result = try await checkSupport()
                checkedSupport = result
                store.runtime.recordAppleLocalModelsSupport(result)
            } catch { self.error = error.localizedDescription }
            checked = true
        }
    }

    @ViewBuilder
    private var content: some View {
        if checking {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Checking model support…").font(.callout).foregroundStyle(.secondary)
            }
        } else if !supported {
            Text("Requires macOS 27 and a Noodle build with custom model support.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if accounts.isEmpty {
            Text("No accounts").font(.callout).foregroundStyle(.secondary)
        } else {
            ForEach(accounts) { account in
                accountCard(account)
                    .padding(12)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func accountCard(_ account: RemoteModelAccount) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name).fontWeight(.medium).lineLimit(1)
                    Text(account.baseURL?.absoluteString ?? account.provider?.displayName ?? account.providerID)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Menu {
                    if account.provider?.describesModels == true {
                        Button("Add Model…") { modelForm = .add(account) }
                    } else {
                        Menu("Models") {
                            ForEach(account.models, id: \.id) { model in
                                let enabled = account.enabledModels.contains(model.id)
                                Toggle(model.displayName, isOn: Binding(get: { enabled }, set: { setModel(model.id, enabled: $0, account: account) }))
                                    .disabled(enabled && !botsUsing(account, model: model.id).isEmpty)
                            }
                        }
                    }
                    Divider()
                    if account.provider?.findsModels == true {
                        Button("Refresh Models") { Task { await refreshModels(account) } }
                    }
                    Button("Rename…") { form = .rename(account) }
                    if account.provider.map(AccountForm.takesKey) ?? true {
                        Button("Change API Key…") { form = .key(account) }
                    }
                    Divider()
                    Button("Remove", role: .destructive) { requestRemoval(account) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Actions for \(account.name)")
                .popover(isPresented: Binding(
                    get: { usageAccountID == account.id },
                    set: { if !$0, usageAccountID == account.id { usageAccountID = nil } }
                ), arrowEdge: .trailing) {
                    ModelUsagePopover(subject: "Account", name: account.tag, agents: botsUsing(account), edit: { agent in
                        returnToAccountID = account.id
                        usageAccountID = nil
                        editingAgent = agent
                    }, remove: { requestRemoval(account) }, close: { usageAccountID = nil })
                }
            }
            let models = account.models.filter { account.enabledModels.contains($0.id) }
            Divider()
            if models.isEmpty {
                Text("No models").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(models, id: \.id) { model in
                let users = botsUsing(account, model: model.id)
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.displayName)
                        Text(model.summary).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .help(users.isEmpty ? "" : "Used by \(users.map(\.displayName).joined(separator: ", ")).")
                    if account.provider?.describesModels == true {
                        Spacer(minLength: 4)
                        Menu {
                            Button("Edit…") { modelForm = .edit(account, model) }
                            Divider()
                            Button("Remove", role: .destructive) { removeModel(model.id, account: account) }
                                .disabled(!users.isEmpty)
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("Actions for \(model.displayName)")
                    }
                }
            }
        }
    }

    private func botsUsing(_ account: RemoteModelAccount, model: String? = nil) -> [AgentRecord] {
        store.agents.filter { agent in
            guard agent.harnessIdentifier == HarnessProvider.apple.rawValue,
                  let id = agent.modelIdentifier.flatMap(RemoteModelID.init) else { return false }
            return id.accountID == account.id && (model == nil || id.modelID == model)
        }
        .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private func reload() throws { accounts = try storage.accounts() }

    private func changed() throws {
        try reload()
        Task { await store.runtime.checkExternalInstallation(.apple) }
    }

    private func setModel(_ model: String, enabled: Bool, account: RemoteModelAccount) {
        do {
            try storage.setModel(model, enabled: enabled, account: account.id)
            try changed()
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func removeModel(_ model: String, account: RemoteModelAccount) {
        do {
            try storage.removeModel(model, account: account.id)
            try changed()
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    /// What the server lists that the account does not have yet; nothing when it cannot be asked.
    private func suggestions(for account: RemoteModelAccount) async -> [String] {
        guard let provider = account.provider, let key = try? storage.apiKey(for: account.id),
              let found = try? await findModels(provider, key) else { return [] }
        return found.map(\.id).filter { id in !account.models.contains { $0.id == id } }
    }

    private func refreshModels(_ account: RemoteModelAccount, quietly: Bool = false) async {
        guard let provider = account.provider else { return }
        do {
            let models = try await findModels(provider, (try? storage.apiKey(for: account.id)) ?? "")
            try storage.setFoundModels(models, account: account.id)
            try changed()
            if !quietly { error = nil }
        } catch where !quietly { self.error = error.localizedDescription } catch {}
    }

    private func save(_ form: AccountForm, name: String, key: String, models: [RemoteModelInfo]?, baseURL: URL?) throws {
        switch form {
        case .add(let provider): try storage.add(providerID: provider.id, name: name, apiKey: key, models: models, baseURL: baseURL)
        case .rename(let account): try storage.rename(account.id, to: name)
        case .key(let account): try storage.replaceKey(account.id, with: key)
        }
        try changed()
        error = nil
    }

    private func requestRemoval(_ account: RemoteModelAccount) {
        guard botsUsing(account).isEmpty else {
            usageAccountID = account.id
            return
        }
        usageAccountID = nil
        accountPendingRemoval = account
    }

    private func remove(_ account: RemoteModelAccount) {
        accountPendingRemoval = nil
        guard botsUsing(account).isEmpty else {
            usageAccountID = account.id
            return
        }
        do {
            try storage.remove(account.id)
            try changed()
        } catch { self.error = error.localizedDescription }
    }
}

private enum AccountForm: Identifiable {
    case add(RemoteProvider)
    case rename(RemoteModelAccount)
    case key(RemoteModelAccount)

    var id: String {
        switch self {
        case .add(let provider): "add-\(provider.id)"
        case .rename(let account): "rename-\(account.id)"
        case .key(let account): "key-\(account.id)"
        }
    }

    var provider: RemoteProvider? {
        switch self {
        case .add(let provider): provider
        case .rename(let account), .key(let account): account.provider
        }
    }

    /// A custom server may or may not want a key.
    static func takesKey(_ provider: RemoteProvider) -> Bool { provider.requiresKey || provider.describesModels }
}

private struct AccountFormView: View {
    let form: AccountForm
    let checkKey: @Sendable (RemoteProvider, String) async throws -> Void
    let findModels: @Sendable (RemoteProvider, String) async throws -> [RemoteModelInfo]
    let save: (String, String, [RemoteModelInfo]?, URL?) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var address = ""
    @State private var key = ""
    @State private var checking = false
    @State private var error: String?

    private var asksName: Bool { if case .key = form { false } else { true } }
    private var asksKey: Bool {
        if case .rename = form { return false }
        return form.provider.map(AccountForm.takesKey) ?? true
    }
    private var needsKey: Bool { asksKey && form.provider?.requiresKey ?? true }
    private var asksAddress: Bool { form.isAdd && form.provider?.id == CustomProvider.id }
    private var title: String {
        switch form {
        case .add(let provider): "Add \(provider.displayName) Account"
        case .rename: "Rename Account"
        case .key: "Change API Key"
        }
    }
    private var ready: Bool {
        (!asksName || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && (!needsKey || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && (!asksAddress || !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            Form {
                if asksName { TextField("Name", text: $name, prompt: Text("Personal")) }
                if asksAddress {
                    TextField("Address", text: $address, prompt: Text(form.provider?.baseURL.absoluteString ?? ""))
                        .textContentType(.URL)
                }
                if asksKey { SecureField("API Key", text: $key, prompt: needsKey ? nil : Text("Optional")) }
            }
            .formStyle(.columns)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if checking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(form.isAdd ? "Add" : "Save", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready || checking)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { if case .rename(let account) = form { name = account.name } }
    }

    private func submit() {
        guard var provider = form.provider else { return }
        let name = name, key = key
        var baseURL: URL?
        error = nil
        if asksAddress {
            do {
                baseURL = try CustomProvider.address(URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)))
                provider = CustomProvider(baseURL: baseURL!)
            } catch { self.error = error.localizedDescription; return }
        }
        checking = true
        Task {
            defer { checking = false }
            do {
                if asksKey { try await checkKey(provider, key.trimmingCharacters(in: .whitespacesAndNewlines)) }
                var models: [RemoteModelInfo]?
                if form.isAdd, provider.findsModels {
                    let found = try await findModels(provider, key)
                    guard !found.isEmpty else {
                        throw HarnessSetupError("\(provider.displayName) has no models that can use tools. Download one, then try again.")
                    }
                    models = found
                }
                try save(name, key, models, baseURL)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

private extension AccountForm {
    var isAdd: Bool { if case .add = self { true } else { false } }
}

private enum ModelForm: Identifiable {
    case add(RemoteModelAccount)
    case edit(RemoteModelAccount, RemoteModelInfo)

    var id: String {
        switch self {
        case .add(let account): "add-\(account.id)"
        case .edit(let account, let model): "edit-\(account.id)-\(model.id)"
        }
    }

    var account: RemoteModelAccount {
        switch self {
        case .add(let account), .edit(let account, _): account
        }
    }

    var model: RemoteModelInfo? { if case .edit(_, let model) = self { model } else { nil } }
}

/// A custom server's model, described by the person because the server cannot.
private struct ModelFormView: View {
    let form: ModelForm
    let suggestions: () async -> [String]
    let save: (RemoteModelInfo) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var id = ""
    @State private var name = ""
    @State private var contextSize = RemoteModelInfo.custom(id: "").contextSize
    @State private var maximumOutputTokens = RemoteModelInfo.custom(id: "").maximumOutputTokens
    @State private var supportsImages = false
    @State private var efforts: Set<String> = []
    @State private var defaultEffort = ""
    @State private var found: [String] = []
    @State private var error: String?

    private static let levelNames = ["none": "None", "low": "Low", "medium": "Medium", "high": "High", "xhigh": "Extra High", "max": "Max"]
    private var chosenEfforts: [String] { RemoteModelInfo.effortLevels.filter(efforts.contains) }
    private var ready: Bool { !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && contextSize > 0 && maximumOutputTokens > 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(form.model == nil ? "Add Model" : "Edit Model").font(.headline)
            Form {
                if let model = form.model {
                    LabeledContent("Model ID") { Text(model.id).textSelection(.enabled) }
                } else {
                    LabeledContent("Model ID") {
                        HStack(spacing: 4) {
                            TextField("Model ID", text: $id, prompt: Text("llama-3.3-70b")).labelsHidden()
                            if !found.isEmpty {
                                Menu {
                                    ForEach(found, id: \.self) { model in Button(model) { id = model } }
                                } label: {
                                    Image(systemName: "chevron.down")
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .accessibilityLabel("Models on the server")
                            }
                        }
                    }
                }
                TextField("Name", text: $name, prompt: Text(id.isEmpty ? "Llama 3.3 70B" : id))
                LabeledContent("Context") {
                    HStack(spacing: 6) {
                        TextField("Context", value: $contextSize, format: .number).labelsHidden().frame(width: 110)
                        Text("tokens").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Maximum Output") {
                    HStack(spacing: 6) {
                        TextField("Maximum Output", value: $maximumOutputTokens, format: .number).labelsHidden().frame(width: 110)
                        Text("tokens").foregroundStyle(.secondary)
                    }
                }
                LabeledContent("Input") { Toggle("Images", isOn: $supportsImages) }
                LabeledContent("Reasoning") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        ForEach([Array(RemoteModelInfo.effortLevels.prefix(3)), Array(RemoteModelInfo.effortLevels.suffix(3))], id: \.self) { row in
                            GridRow {
                                ForEach(row, id: \.self) { level in
                                    Toggle(Self.levelNames[level] ?? level, isOn: Binding(
                                        get: { efforts.contains(level) },
                                        set: { on in
                                            if on { efforts.insert(level) } else { efforts.remove(level) }
                                            if !efforts.contains(defaultEffort) {
                                                defaultEffort = efforts.contains("medium") ? "medium" : chosenEfforts.first ?? ""
                                            }
                                        }))
                                }
                            }
                        }
                    }
                }
                if !chosenEfforts.isEmpty {
                    Picker("Default Reasoning", selection: $defaultEffort) {
                        ForEach(chosenEfforts, id: \.self) { Text(Self.levelNames[$0] ?? $0).tag($0) }
                    }
                    .fixedSize()
                }
            }
            .formStyle(.columns)
            .toggleStyle(.switch)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(form.model == nil ? "Add" : "Save", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            guard let model = form.model else { return }
            id = model.id
            name = model.displayName == model.id ? "" : model.displayName
            contextSize = model.contextSize
            maximumOutputTokens = model.maximumOutputTokens
            supportsImages = model.supportsImages
            efforts = Set(model.efforts.map(\.id))
            defaultEffort = model.defaultEffort
        }
        .task { if form.model == nil { found = await suggestions() } }
    }

    private func submit() {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try save(RemoteModelInfo(id: id, displayName: name, contextSize: contextSize, maximumOutputTokens: maximumOutputTokens,
                                     supportsImages: supportsImages, efforts: RemoteModelInfo.efforts(chosenEfforts),
                                     defaultEffort: chosenEfforts.isEmpty ? "" : defaultEffort))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
