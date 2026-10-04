import HubCore
import HubLink
import SwiftUI

/// Whether a Hub's devices can reach it, near and away from home, and the addresses invitations
/// carry: rows in a settings form, the same in Noodle Hub and in Noodle serving its owner's devices.
public struct HubLinkRows<Extra: View>: View {
    @Bindable var link: HubLinkService
    /// Labels the status as a row of its own, where no switch above it says what it is about.
    let statusTitle: String?
    /// Rows of the app's own, between the status and the router.
    let extra: Extra
    @State private var editingAddress = false
    @State private var address = ""
    @State private var name = ""
    @FocusState private var editingName: Bool

    public init(link: HubLinkService, statusTitle: String? = nil, @ViewBuilder extra: () -> Extra = { EmptyView() }) {
        self.link = link
        self.statusTitle = statusTitle
        self.extra = extra()
    }

    public var body: some View {
        if let statusTitle {
            LabeledContent(statusTitle) { status }
        } else {
            status
        }
        extra
        LabeledContent("Name") {
            HStack(spacing: 4) {
                TextField("Name", text: $name, prompt: Text(link.macName))
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .focused($editingName)
                    .onSubmit { link.customName = name }
                if !link.customName.isEmpty {
                    Button {
                        link.customName = ""
                        name = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .help("Use this Mac’s name")
                }
            }
        }
        .help("What paired devices call this Hub")
        .onAppear { name = link.customName }
        .onChange(of: editingName) { if !editingName { link.customName = name } }
        .onChange(of: link.customName) { if !editingName { name = link.customName } }
        Toggle(isOn: $link.opensRouterPort) {
            Text("Open Port on Router")
            routerStatus
        }
        .help("Asks the router, through UPnP or NAT-PMP, to forward the port so devices reach it away from home")
        Picker("Largest File", selection: $link.uploadLimit) {
            ForEach(link.uploadLimitChoices, id: \.self) { limit in
                Text(ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)).tag(limit)
            }
        }
        .help("The largest file a device can send to a conversation here")
        LabeledContent("Addresses") {
            Grid(alignment: .trailing, horizontalSpacing: 8, verticalSpacing: 2) {
                ForEach(link.endpoints, id: \.self) { endpoint in
                    GridRow {
                        HStack(spacing: 4) {
                            Text(endpoint.description).font(.caption.monospaced()).textSelection(.enabled)
                            if endpoint == link.manualEndpoint {
                                Button {
                                    link.manualAddress = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                                .help("Remove this address")
                            }
                        }
                        Text(Self.name(of: endpoint.network)).font(.caption).foregroundStyle(.tertiary)
                            .gridColumnAlignment(.leading)
                    }
                }
            }
        }
        .alert("Remote Address", isPresented: $editingAddress) {
            TextField("Address", text: $address, prompt: Text("mac.example.com"))
            Button("Cancel", role: .cancel) {}
            Button("Save") { link.manualAddress = address.trimmingCharacters(in: .whitespaces) }
                .disabled(LinkEndpoint(text: address, defaultPort: LinkEndpoint.defaultPort) == nil)
        } message: {
            Text("A domain, public address or forwarded port that reaches this Mac from outside your network.")
        }
        if link.manualEndpoint == nil {
            HStack {
                Spacer()
                Button("Add Remote Address…") {
                    address = ""
                    editingAddress = true
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch link.state {
        case .listening:
            let reachability = link.reachability
            if reachability.isWarning {
                SettingsStatusLabel(title: reachability.summary, systemImage: "exclamationmark.circle.fill", color: .orange)
            } else {
                SettingsStatusLabel(title: reachability.summary, systemImage: "checkmark.circle.fill", color: .green)
            }
        case .failed(let reason):
            SettingsStatusLabel(title: reason, systemImage: "exclamationmark.circle.fill", color: .orange)
        case .starting, .stopped:
            SettingsStatusLabel(title: "Starting…", systemImage: "circle.dotted", color: .secondary)
        }
    }

    @ViewBuilder private var routerStatus: some View {
        switch link.router {
        case .off: EmptyView()
        case .opening: Text("Asking the router…")
        case .open(let mapping): Text("Open at \(mapping.endpoint.host)")
        case .failed(let reason): Text(reason).foregroundStyle(.orange)
        }
    }

    private static func name(of network: LinkEndpoint.Network) -> String {
        switch network {
        case .home: "home"
        case .tailnet: "tailscale"
        case .internet: "internet"
        }
    }
}
