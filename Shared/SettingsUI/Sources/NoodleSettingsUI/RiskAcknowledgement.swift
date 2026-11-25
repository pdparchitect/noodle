import AppKit
import SwiftUI

/// Terms a person accepts once, by typing a phrase, before using an app whose risks they must understand, such as
/// Rook's. Accepting is remembered per version, so new terms are asked again.
public struct RiskAcknowledgement: Sendable {
    public let id: String
    public let version: Int
    public let appName: String
    public let title: String
    public let message: String
    public let phrase: String

    public init(id: String, version: Int, appName: String, title: String, message: String, phrase: String) {
        self.id = id
        self.version = version
        self.appName = appName
        self.title = title
        self.message = message
        self.phrase = phrase
    }

    var key: String { "RiskAcknowledgement.\(id).v\(version)" }

    public func isAccepted(in defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: key) }
    public func accept(in defaults: UserDefaults = .standard) { defaults.set(true, forKey: key) }
    /// Asks again, as when rehearsing a first launch.
    public func reset(in defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }

    /// Whether `typed` is the phrase: whole, ignoring case and the spaces around it.
    func matches(_ typed: String) -> Bool {
        typed.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(phrase) == .orderedSame
    }
}

extension View {
    /// Asks for `terms` once, a moment after `ready` turns true, so a window that is still settling, or showing
    /// something else first such as a welcome, is not interrupted. Until accepted, the only other way out is quitting.
    public func riskAcknowledgement(_ terms: RiskAcknowledgement, ready: Bool, defaults: UserDefaults = .standard) -> some View {
        modifier(RiskAcknowledgementPresenter(terms: terms, ready: ready, defaults: defaults))
    }
}

private struct RiskAcknowledgementPresenter: ViewModifier {
    let terms: RiskAcknowledgement
    let ready: Bool
    let defaults: UserDefaults
    @State private var presenting = false
    /// One sheet at a time, however many windows ask.
    @MainActor private static var shown: Set<String> = []

    func body(content: Content) -> some View {
        content
            .task(id: ready) {
                guard ready, !terms.isAccepted(in: defaults), !Self.shown.contains(terms.key) else { return }
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled, !terms.isAccepted(in: defaults), Self.shown.insert(terms.key).inserted else { return }
                presenting = true
            }
            .sheet(isPresented: $presenting, onDismiss: { Self.shown.remove(terms.key) }) {
                RiskAcknowledgementSheet(terms: terms) {
                    terms.accept(in: defaults)
                    presenting = false
                }
            }
    }
}

struct RiskAcknowledgementSheet: View {
    let terms: RiskAcknowledgement
    let accept: () -> Void
    @State private var typed = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(terms.title).font(.title2.weight(.semibold))
            Text(terms.message).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Type “\(terms.phrase)” to continue.").font(.callout).foregroundStyle(.secondary)
                TextField(terms.phrase, text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled(true)
                    .focused($focused)
                    .onSubmit { if terms.matches(typed) { accept() } }
            }
            HStack {
                Spacer()
                Button("Quit \(terms.appName)") { NSApplication.shared.terminate(nil) }
                Button("Accept", action: accept)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!terms.matches(typed))
            }
        }
        .padding(24)
        .onAppear { focused = true }
        .interactiveDismissDisabled()
        .frame(width: 480)
        .noodleSheetSizing()
    }
}
