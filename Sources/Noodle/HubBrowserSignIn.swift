import AppKit
import HubLink
import NoodleHubClient
import NoodleSettingsUI
import SwiftUI
import NoodleRuntimeSettings

/// Signing in to the page of a Hub bot's browser watched live in a panel, as on the iPhone: the header's
/// Sign In… button asks the Hub once for the page's fields, and the live view shows them in a sheet.
@MainActor @Observable final class HubBrowserSignIn {
    let target: HubSurfaceTarget
    private let mirror: HubMirror?
    /// Whether the picture shows, so there is a page to sign in to.
    var showing = false
    /// The sign-in fields of the page shown, while the sheet for them is open.
    var form: LinkSignInForm?
    var problem: String?
    private(set) var finding = false

    init(target: HubSurfaceTarget, mirror: HubMirror?) {
        self.target = target
        self.mirror = mirror
    }

    /// Only a Hub whose status says it signs in to browsers offers it; older Hubs never show the button.
    var available: Bool { showing && mirror?.signsInToBrowsers == true }

    /// Asks the Hub, once, for the sign-in fields of the page shown.
    func find() {
        guard let mirror else { return }
        finding = true
        Task {
            defer { finding = false }
            do { form = try await mirror.signInForm(attachment: target.attachmentID, in: target.conversationID) }
            catch { problem = error.localizedDescription }
        }
    }

    func fill(_ entry: LinkSignInEntry, form: LinkSignInForm) async throws {
        guard let mirror else { throw LinkError("Join that Noodle Hub again to open this.") }
        try await mirror.fillSignIn(entry, form: form, attachment: target.attachmentID, in: target.conversationID)
    }
}

/// The live view's header button for signing in to the page shown.
struct HubBrowserSignInButton: View {
    let signIn: HubBrowserSignIn

    var body: some View {
        if signIn.available {
            // Grey, as everything in a preview's header is.
            Button("Sign In…", action: signIn.find).disabled(signIn.finding)
                .buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 11, weight: .medium))
        }
    }
}

/// Native fields for a page's sign-in form, so AutoFill offers this Mac's passwords and codes from
/// Messages. The site they go to is shown first, with a warning when it is not the page's own or not secure.
struct HubBrowserSignInSheet: View {
    let form: LinkSignInForm
    let send: (LinkSignInEntry) async throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var entry = LinkSignInEntry()
    @State private var working = false
    @State private var problem: String?
    @FocusState private var focused: LinkSignInField.Kind?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(.sheetHeader).keyboardShortcut(.cancelAction).disabled(working)
                Spacer()
                Text("Sign In").font(.headline)
                Spacer()
                Button("Fill", action: fill).buttonStyle(.sheetHeader).keyboardShortcut(.defaultAction).disabled(working || entry.isEmpty)
            }.padding(16)
            Divider()
            Form {
                Section { LinkSignInSite(form) }
                Section {
                    if form.has(.username, .email) {
                        TextField(form.has(.email) && !form.has(.username) ? "Email" : "Username", text: $entry.username)
                            .textContentType(.username).autocorrectionDisabled()
                            .focused($focused, equals: .username)
                    }
                    if form.has(.password) {
                        SecureField("Password", text: $entry.password).textContentType(.password).focused($focused, equals: .password)
                    }
                    if form.has(.newPassword) {
                        SecureField("New Password", text: $entry.newPassword).textContentType(.newPassword)
                            .focused($focused, equals: .newPassword)
                    }
                    if form.has(.oneTimeCode) {
                        TextField("Code", text: $entry.oneTimeCode).textContentType(.oneTimeCode).autocorrectionDisabled()
                            .focused($focused, equals: .oneTimeCode)
                    }
                    Toggle("Submit", isOn: $entry.submit)
                }
                if let problem { Text(problem).font(.caption).foregroundStyle(.red) }
            }.formStyle(.grouped).disabled(working)
        }
        .privacySensitive()
        // Closing it while the values are on their way would lose what the Hub says about them.
        .interactiveDismissDisabled(working)
        .frame(width: 420)
        .noodleSheetSizing()
        .onAppear { focused = form.firstField }
        // What was typed goes once; nothing of it stays behind.
        .onDisappear { entry = LinkSignInEntry() }
    }

    private func fill() {
        working = true
        problem = nil
        Task {
            defer { working = false }
            do {
                try await send(entry)
                entry = LinkSignInEntry()
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}
