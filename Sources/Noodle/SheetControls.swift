import NoodleCore
import NoodleRuntimeSettings
import SwiftUI

// The pieces every app's create and edit sheets are made of, so they look and behave alike.

/// A sheet's top bar: Cancel, the title, and the action, dimmed until it can run. Return stays with the focused text field.
struct SheetHeader: View {
    var heading = ""
    let title: String
    let enabled: Bool
    let action: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .keyboardShortcut(.cancelAction)
            Spacer()
            Text(heading).font(.headline)
            Spacer()
            Button(title, action: action)
                .buttonStyle(.plain)
                .foregroundStyle(enabled ? Color.blue : .secondary)
                .disabled(!enabled)
        }
        .padding(16)
    }
}

/// The sections of an editor, centred at their own width.
struct SheetTabPicker<Tab: RawRepresentable & CaseIterable & Hashable>: View where Tab.RawValue == String, Tab.AllCases: RandomAccessCollection {
    var label = "Section"
    @Binding var selection: Tab
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Picker(label, selection: $selection.animation(reduceMotion ? nil : .easeInOut(duration: 0.22))) {
            ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

/// Why a bot's, agent's or group's name cannot be used, under its field.
struct NameValidationMessage: View {
    let name: String
    var body: some View {
        if !name.isEmpty, let error = ConversationName.error(for: name) {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A short description of a few lines, titled above and explained beneath.
struct SheetDescriptionField: View {
    let title: String
    let prompt: String
    @Binding var text: String
    var lines: ClosedRange<Int> = 2...4
    var footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold))
            TextField(prompt, text: $text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(lines)
                .autocorrectionDisabled(false)
                .accessibilityLabel(title)
            if let footnote { Text(footnote).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// A bot's backstory or instructions: a fixed-height editor, titled above and explained beneath.
struct SheetInstructionsEditor: View {
    let title: String
    @Binding var text: String
    var prompt = ""
    var footnote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold))
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(size: 13))
                    .autocorrectionDisabled(false)
                    .roundedBorderEditor()
                    .accessibilityLabel(title)
                if text.isEmpty && !prompt.isEmpty {
                    // The editor's outer inset; the text view adds its own line-fragment padding.
                    Text(prompt)
                        .font(.system(size: 13))
                        .foregroundStyle(Color(nsColor: .placeholderTextColor))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 160)
            if let footnote { Text(footnote).font(.caption).foregroundStyle(.secondary) }
        }
    }
}
