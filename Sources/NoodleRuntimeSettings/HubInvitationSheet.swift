import AppKit
import HubCore
import HubLink
import SwiftUI

/// One invitation for one user: a QR code and the same link to copy or share.
public struct HubInvitationSheet: View {
    let access: HubAccess?
    let user: HubUser?
    let invitation: LinkInvitation
    let title: String
    @Environment(\.dismiss) private var dismiss

    /// `title` heads the sheet, "Invite" and the user's name unless given. Without `access`, as
    /// on a device managing a Hub, the sheet cannot tell when the device joined.
    public init(access: HubAccess?, user: HubUser?, invitation: LinkInvitation, title: String? = nil) {
        self.access = access
        self.user = user
        self.invitation = invitation
        self.title = title ?? "Invite \(invitation.userName)"
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 16) {
                Text(title).font(.title2.bold())
                HubInvitationView(access: access, user: user, invitation: invitation)
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
}

/// An invitation's QR code, its link to copy or share, and whether it was used or ran out.
public struct HubInvitationView: View {
    let access: HubAccess?
    let user: HubUser?
    let invitation: LinkInvitation
    let renew: (() -> Void)?
    @State private var opened = Date()

    /// With `access` and `user`, says when a device of the user joined; `renew` makes a new
    /// invitation once this one expires.
    public init(access: HubAccess?, user: HubUser?, invitation: LinkInvitation, renew: (() -> Void)? = nil) {
        self.access = access
        self.user = user
        self.invitation = invitation
        self.renew = renew
    }

    private var url: URL { invitation.url() }

    /// A device of this user that paired while the invitation was shown.
    private var joined: HubDevice? {
        guard let access, let user else { return nil }
        return access.devices(of: user).filter { $0.paired >= opened.addingTimeInterval(-1) }.max { $0.paired < $1.paired }
    }

    public var body: some View {
        VStack(spacing: 16) {
            if let code = invitation.qrCode() {
                Image(decorative: code, scale: 1)
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
            Text("Hub key \(invitation.hubKey.fingerprint)")
                .font(.caption.monospaced())
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
                    if context.date < invitation.expires {
                        Text("Expires \(invitation.expires, format: .relative(presentation: .named))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if let renew {
                        Button("New Invitation", action: renew)
                    } else {
                        Text("Expired").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}
