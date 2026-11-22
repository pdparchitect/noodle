import SwiftUI

enum SidebarItemDensity: Sendable {
    case standard, compact

    var rowPicture: CGFloat { self == .compact ? 22 : 42 }
    var tilePicture: CGFloat { self == .compact ? 36 : 60 }
    var rowHeight: CGFloat { self == .compact ? 30 : 66 }
}

private struct SidebarItemDensityKey: EnvironmentKey {
    static let defaultValue = SidebarItemDensity.standard
}

extension EnvironmentValues {
    var sidebarItemDensity: SidebarItemDensity {
        get { self[SidebarItemDensityKey.self] }
        set { self[SidebarItemDensityKey.self] = newValue }
    }
}

struct SidebarGridHeading: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The content geometry used by Noodle's sidebar. Hosts supply their own artwork, text and actions.
struct SidebarItemRow<Picture: View>: View {
    var title: String
    var detail: String
    var timestamp = ""
    var pause: String?
    @Environment(\.sidebarItemDensity) private var density
    @ViewBuilder var picture: (CGFloat) -> Picture

    var body: some View {
        HStack(spacing: density == .compact ? 8 : 10) {
            picture(density.rowPicture)
            if density == .compact {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title).font(.callout.weight(.semibold)).lineLimit(1).layoutPriority(1)
                    Text(pause ?? detail).font(.caption)
                        .foregroundStyle(pause == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.red))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .help([title, pause, detail, timestamp].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(title).font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(timestamp).font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    }
                    if let pause {
                        Text(pause).font(.system(size: 12.5, weight: .medium)).foregroundStyle(.red).lineLimit(1)
                    }
                    Text(detail).font(.system(size: 12.5)).foregroundStyle(.secondary)
                        .lineLimit(pause == nil ? 2 : 1).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(height: density.rowHeight)
        .contentShape(Rectangle())
    }
}

extension View {
    func sidebarItemInsets() -> some View {
        modifier(SidebarRowInsets())
    }
}

private struct SidebarRowInsets: ViewModifier {
    @Environment(\.sidebarItemDensity) private var density

    func body(content: Content) -> some View {
        content
            .listRowInsets(density == .compact ? EdgeInsets(top: 1, leading: 14, bottom: 1, trailing: 8)
                                               : EdgeInsets(top: 2, leading: 14, bottom: 2, trailing: 10))
            .listRowSeparator(.visible, edges: .bottom)
            .listRowSeparatorTint(Color.primary.opacity(0.12))
    }
}

struct SidebarItemTile<Picture: View>: View {
    var title: String
    var detail: String
    var tone = AnyShapeStyle(.secondary)
    var emphasized = false
    var selected = false
    var targeted = false
    @Environment(\.sidebarItemDensity) private var density
    @ViewBuilder var picture: (CGFloat) -> Picture

    var body: some View {
        VStack(spacing: 4) {
            picture(density.tilePicture).padding(.top, density == .compact ? 2 : 4)
            Text(title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text(detail).font(.system(size: 10.5, weight: emphasized ? .medium : .regular))
                .foregroundStyle(tone).multilineTextAlignment(.center).lineLimit(2)
                .frame(height: 28, alignment: .top)
        }
        .padding(.vertical, density == .compact ? 4 : 6).padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .background {
            if selected || targeted {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.accentColor.opacity(targeted ? 0.25 : 0.18)).accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }
}
