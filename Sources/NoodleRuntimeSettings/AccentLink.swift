import AppKit
import SwiftUI

/// The colour of links, in text and as buttons: the accent, the app's own or the one the person chose in System Settings,
/// as the controls around them have, rather than the system's fixed link blue. In dark appearance a deep accent is
/// lightened just enough to read as text on a dark window; a bright one, such as yellow, is left as it is.
public enum AccentLink {
    /// The relative luminance link text needs on a dark window: about 4 to 1 against it.
    public static let readableLuminance: CGFloat = 0.25

    public static let color = Color(nsColor: NSColor(name: nil) { appearance in
        let accent = NSColor.controlAccentColor
        guard appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua else { return accent }
        return readable(accent)
    })

    /// `accent` lightened towards white in small steps, only until it reads on a dark window.
    public static func readable(_ accent: NSColor) -> NSColor {
        guard let colour = accent.usingColorSpace(.sRGB) else { return accent }
        var result = colour, fraction: CGFloat = 0
        while luminance(result) < readableLuminance, fraction < 1 {
            fraction += 0.02
            result = colour.blended(withFraction: fraction, of: .white) ?? colour
        }
        return result
    }

    /// How bright a colour looks, from 0 for black to 1 for white, as contrast guidelines measure it.
    public static func luminance(_ colour: NSColor) -> CGFloat {
        guard let rgb = colour.usingColorSpace(.sRGB) else { return 0 }
        func linear(_ value: CGFloat) -> CGFloat { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(rgb.redComponent) + 0.7152 * linear(rgb.greenComponent) + 0.0722 * linear(rgb.blueComponent)
    }
}

/// The system's link button style in the accent's link colour. The system's own keeps its fixed blue whatever the
/// accent, and no tint changes it, so the colour is set on the label, which also stops the system dimming it when
/// disabled; it is dimmed here instead, by half, as the system dims its own.
public struct AccentLinkButtonStyle: PrimitiveButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        AccentLinkButton(configuration: configuration)
    }

    private struct AccentLinkButton: View {
        let configuration: PrimitiveButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let button = Button(role: configuration.role, action: configuration.trigger) { configuration.label }
                .buttonStyle(.link)
            // A destructive link keeps the system's own colour for it.
            if configuration.role == .destructive {
                button
            } else {
                button.foregroundStyle(AccentLink.color.opacity(isEnabled ? 1 : 0.5))
            }
        }
    }
}

public extension PrimitiveButtonStyle where Self == AccentLinkButtonStyle {
    /// A link in the accent's link colour, for buttons that read as links, such as those in a list's rows.
    static var accentLink: AccentLinkButtonStyle { AccentLinkButtonStyle() }
}
