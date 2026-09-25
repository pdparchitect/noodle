import AppKit
import CoreImage.CIFilterBuiltins
import HubCore
import HubLink
import SwiftUI

/// One invitation for one user: a QR code and the same link to copy or share.
struct HubInvitationSheet: View {
    let access: HubAccess
    let user: HubUser
    let invitation: LinkInvitation
    @Environment(\.dismiss) private var dismiss
    @State private var opened = Date()

    private var url: URL { invitation.url() }

    /// A device of this user that paired while the sheet was open.
    private var joined: HubDevice? {
        access.devices(of: user).filter { $0.paired >= opened.addingTimeInterval(-1) }.max { $0.paired < $1.paired }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                Text("Invite \(user.name)").font(.title2.bold())
                if let image = Self.qrCode(url.absoluteString) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 200, height: 200)
                        .padding(10)
                        .background(.white, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("Invitation QR Code")
                }
                Text(url.absoluteString)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                    ShareLink("Share…", item: url)
                }
                if let joined {
                    Label("“\(joined.name)” joined", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(context.date < invitation.expires
                             ? "Expires \(invitation.expires, format: .relative(presentation: .named))"
                             : "Expired")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(24)
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 400)
        .fixedSize(horizontal: false, vertical: true)
    }

    static func qrCode(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}

/// Whether devices can reach the Hub, and the addresses invitations carry.
struct HubNetworkSettingsView: View {
    @Bindable var link: HubLinkService
    @State private var editingAddress = false
    @State private var address = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    switch link.state {
                    case .listening(let port): Text("Listening on port \(String(port))")
                    case .starting: Text("Starting…")
                    case .stopped: Text("Stopped")
                    case .failed(let message): Text(message).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                TimelineView(.periodic(from: .now, by: 15)) { _ in
                    LabeledContent("Connected") {
                        let people = link.connectedUsers.count, devices = link.connectedDevices.count
                        Text(devices == 0 ? "No one"
                             : "\(people) \(people == 1 ? "person" : "people") on \(devices) \(devices == 1 ? "device" : "devices")")
                    }
                }
            }
            Section("Addresses") {
                ForEach(link.endpoints.filter { $0 != link.manualEndpoint }, id: \.self) { endpoint in
                    Text(endpoint.description).font(.body.monospaced()).textSelection(.enabled)
                }
                if let manual = link.manualEndpoint {
                    HStack {
                        Text(manual.description).font(.body.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button("Remove") { link.manualAddress = "" }
                    }
                    .help("Reaches this Mac from outside your network")
                }
            }
        }
        .formStyle(.grouped)
        .accessFooter(link.manualEndpoint == nil ? "Add Address" : "Change Address") {
            address = link.manualAddress
            editingAddress = true
        }
        .alert("Remote Address", isPresented: $editingAddress) {
            TextField("Address", text: $address, prompt: Text("hub.example.com"))
            Button("Cancel", role: .cancel) {}
            Button("Save") { link.manualAddress = address.trimmingCharacters(in: .whitespaces) }
                .disabled(LinkEndpoint(text: address, defaultPort: LinkEndpoint.defaultPort) == nil)
        } message: {
            Text("A domain, public address or forwarded port that reaches this Mac from outside your network.")
        }
    }
}
