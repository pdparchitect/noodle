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
    @State private var accountPendingRemoval: RemoteModelAccount?
    @State private var usageAccountID: UUID?
    @State private var editingAgent: AgentRecord?
    @State private var returnToAccountID: UUID?
    @State private var listHeight: CGFloat = 0
    private let accountStore: RemoteModelAccountStore?
    private let checkSupport: @MainActor () async throws -> Bool
    private let checkKey: @Sendable (RemoteProvider, String) async throws -> Void
    private let findModels: @Sendable (RemoteProvider) async throws -> [RemoteModelInfo]

    init(store: any BotSettingsHost, accountStore: RemoteModelAccountStore? = nil,
         checkSupport: @escaping @MainActor () async throws -> Bool = { try await AppleHostProbe.load().localModelsSupported == true },
         checkKey: @escaping @Sendable (RemoteProvider, String) async throws -> Void = { try await $0.checkKey($1) },
         findModels: @escaping @Sendable (RemoteProvider) async throws -> [RemoteModelInfo] = { try await $0.findModels() }) {
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
            AccountFormView(form: form, checkKey: checkKey, findModels: findModels) { name, key, models in
                try save(form, name: name, key: key, models: models)
            }
        }
        .sheet(item: $editingAgent, onDismiss: {
            if let id = returnToAccountID, accounts.contains(where: { $0.id == id }) { usageAccountID = id }
            returnToAccountID = nil
        }) { agent in
            store.botRuntimeEditor(agent)
                .noodleSheetSizing(animated: true)
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
                    Text(account.provider?.displayName ?? account.providerID).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Menu {
                    Menu("Models") {
                        ForEach(account.models, id: \.id) { model in
                            let enabled = account.enabledModels.contains(model.id)
                            Toggle(model.displayName, isOn: Binding(get: { enabled }, set: { setModel(model.id, enabled: $0, account: account) }))
                                .disabled(enabled && !botsUsing(account, model: model.id).isEmpty)
                        }
                    }
                    Divider()
                    if account.provider?.findsModels == true {
                        Button("Refresh Models") { Task { await refreshModels(account) } }
                    }
                    Button("Rename…") { form = .rename(account) }
                    if account.provider?.requiresKey ?? true {
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
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                    Text(model.summary).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .help(users.isEmpty ? "" : "Used by \(users.map(\.displayName).joined(separator: ", ")).")
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

    private func refreshModels(_ account: RemoteModelAccount, quietly: Bool = false) async {
        guard let provider = account.provider else { return }
        do {
            let models = try await findModels(provider)
            try storage.setFoundModels(models, account: account.id)
            try changed()
            if !quietly { error = nil }
        } catch where !quietly { self.error = error.localizedDescription } catch {}
    }

    private func save(_ form: AccountForm, name: String, key: String, models: [RemoteModelInfo]?) throws {
        switch form {
        case .add(let provider): try storage.add(providerID: provider.id, name: name, apiKey: key, models: models)
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
}

private struct AccountFormView: View {
    let form: AccountForm
    let checkKey: @Sendable (RemoteProvider, String) async throws -> Void
    let findModels: @Sendable (RemoteProvider) async throws -> [RemoteModelInfo]
    let save: (String, String, [RemoteModelInfo]?) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var key = ""
    @State private var checking = false
    @State private var error: String?

    private var asksName: Bool { if case .key = form { false } else { true } }
    private var asksKey: Bool {
        if case .rename = form { return false }
        return form.provider?.requiresKey ?? true
    }
    private var title: String {
        switch form {
        case .add(let provider): "Add \(provider.displayName) Account"
        case .rename: "Rename Account"
        case .key: "Change API Key"
        }
    }
    private var ready: Bool {
        (!asksName || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && (!asksKey || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            Form {
                if asksName { TextField("Name", text: $name, prompt: Text("Personal")) }
                if asksKey { SecureField("API Key", text: $key) }
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
        guard let provider = form.provider else { return }
        let name = name, key = key
        checking = true
        error = nil
        Task {
            defer { checking = false }
            do {
                if asksKey { try await checkKey(provider, key.trimmingCharacters(in: .whitespacesAndNewlines)) }
                var models: [RemoteModelInfo]?
                if form.isAdd, provider.findsModels {
                    let found = try await findModels(provider)
                    guard !found.isEmpty else {
                        throw HarnessSetupError("\(provider.displayName) has no models that can use tools. Download one, then try again.")
                    }
                    models = found
                }
                try save(name, key, models)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

private extension AccountForm {
    var isAdd: Bool { if case .add = self { true } else { false } }
}
