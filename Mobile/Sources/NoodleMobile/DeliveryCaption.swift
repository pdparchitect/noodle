import SwiftUI

/// How far your message got: one check when sent, two when delivered, anything else in words, as on the Mac.
/// The words stay for VoiceOver. The checks are text, so they keep the caption's height, and they always take
/// the width of two, so going from one to two moves nothing.
struct DeliveryCaption: View {
    /// What the conversation says about it, in the Mac's words.
    let delivery: String
    var failed = false

    /// How many check marks stand for `delivery`; nil where it stays in words.
    static func checks(for delivery: String) -> Int? {
        switch delivery {
        case "Sent": 1
        case "Delivered": 2
        default: nil
        }
    }

    var body: some View {
        Group {
            if let checks = Self.checks(for: delivery) {
                ZStack(alignment: .trailing) {
                    Self.marks(2).hidden()
                    Self.marks(checks)
                }
            } else {
                Text(delivery)
            }
        }
        .font(.caption2)
        .foregroundStyle(failed ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(delivery)
    }

    private static func marks(_ count: Int) -> Text {
        let check = Image(systemName: "checkmark")
        return count == 1 ? Text(check) : Text("\(check)\(check)").tracking(-3)
    }
}
