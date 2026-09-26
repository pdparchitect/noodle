import AppKit
import CoreImage.CIFilterBuiltins
import HubCore
import HubLink
import SwiftUI

/// One invitation for one user: a QR code and the same link to copy or share.
public struct HubInvitationSheet: View {
    let access: HubAccess
    let user: HubUser
    let invitation: LinkInvitation
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var opened = Date()

    private var url: URL { invitation.url() }

    /// A device of this user that paired while the sheet was open.
    private var joined: HubDevice? {
        access.devices(of: user).filter { $0.paired >= opened.addingTimeInterval(-1) }.max { $0.paired < $1.paired }
    }

    /// `title` heads the sheet, "Invite" and the user's name unless given.
    public init(access: HubAccess, user: HubUser, invitation: LinkInvitation, title: String? = nil) {
        self.access = access
        self.user = user
        self.invitation = invitation
        self.title = title ?? "Invite \(user.name)"
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                Text(title).font(.title2.bold())
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

    public static func qrCode(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
