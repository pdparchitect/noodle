import SwiftUI

/// The composer's send control, shared by Noodle, Pion and Rook: an outline arrow while there is nothing to send,
/// and a white arrow on the app's own accent once there is.
struct ComposerSendButton: View {
    let canSend: Bool
    let width: CGFloat
    let height: CGFloat
    let help: String
    let send: () -> Void

    var body: some View {
        if canSend {
            Button(action: send) {
                // A white arrow on the accent, rather than one cut out of it, reads the same in light and dark.
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 23))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, Color.accentColor)
                    .frame(width: width, height: height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(help)
        } else {
            Image(systemName: "arrow.up.circle")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
                .frame(width: width, height: height)
        }
    }
}
