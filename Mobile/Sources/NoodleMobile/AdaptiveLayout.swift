import SwiftUI
import UIKit

/// How the home screen lays out the bots and conversations in the room it has.
enum HomeLayout: Equatable {
    /// One column: the list, with a conversation pushed over it, as on every iPhone.
    case stack
    /// One column, with the pinned bots in the system's vertical bar beside it, as on the iPhone Duo's cover screen.
    case stackBesideBar
    /// The list in a column on the left and the open conversation beside it, as on the Mac: on iPad and the
    /// unfolded iPhone Duo.
    case split

    /// Two columns need room for the list and a readable conversation, across and down: an iPhone turned on
    /// its side is wide enough, but too short, and keeps one column.
    static let splitWidth: CGFloat = 700
    static let splitHeight: CGFloat = 500

    /// The layout for the room inside the safe area, and the edge of the system's vertical bar, if there is one.
    static func choose(size: CGSize, verticalBar: HorizontalEdge?) -> HomeLayout {
        if isWide(size) { return .split }
        return verticalBar == nil ? .stack : .stackBesideBar
    }

    /// Whether a screen or window this size is an iPad's or the unfolded iPhone Duo's rather than a phone's,
    /// upright or on its side: room for two columns.
    static func isWide(_ size: CGSize) -> Bool { size.width >= splitWidth && size.height >= splitHeight }

    /// Whether the list shows the pinned bots above the others; beside the vertical bar they are in the bar.
    var pinsInList: Bool { self != .stackBesideBar }
}

/// The room of the app window, excluding system bars but not the keyboard. A keyboard changes
/// SwiftUI's proposed height; that must not swap the navigation hierarchy and replace its editor.
struct HomeViewportReader: UIViewRepresentable {
    @Binding var size: CGSize

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: Probe, context: Context) {
        view.changed = { size = $0 }
        view.setNeedsLayout()
    }

    final class Probe: UIView {
        var changed: ((CGSize) -> Void)?
        private var reported: CGSize?

        override func didMoveToWindow() { super.didMoveToWindow(); setNeedsLayout() }
        override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); setNeedsLayout() }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let window else { return }
            let size = window.bounds.inset(by: window.safeAreaInsets).size
            guard size.width > 0, size.height > 0, size != reported else { return }
            reported = size
            // Layout may be in a SwiftUI update. Deliver the measured window size afterwards.
            DispatchQueue.main.async { [weak self] in self?.changed?(size) }
        }
    }
}

/// Which conversation is open: pushed over the list in one column, or selected beside it in two.
struct HomeNavigation: Equatable {
    /// The conversations over the list in one column, the latest on top.
    var path: [ChatLink] = []
    /// The conversation beside the list in two columns.
    var selection: ChatLink?

    /// Opens a conversation from the list, a notification, a widget or a link, alone over the list or beside it.
    mutating func open(_ link: ChatLink, in layout: HomeLayout) {
        if layout == .split {
            selection = link
            path = []
        } else {
            path = [link]
            selection = nil
        }
    }

    /// Opens a conversation from another, as a bot's profile in a group does: in one column on top, or back to
    /// it when it is open beneath; in two it is selected, as a row tapped in the list is.
    mutating func openFromConversation(_ link: ChatLink, in layout: HomeLayout) {
        if layout == .split {
            open(link, in: layout)
        } else {
            path = ChatLink.path(path, opening: link)
        }
    }

    /// The conversation on top stays open when the layout changes, as when the iPhone Duo is unfolded or folded,
    /// or an iPad window is resized.
    mutating func adapt(from old: HomeLayout, to new: HomeLayout) {
        switch (old == .split, new == .split) {
        case (false, true):
            selection = path.last
            path = []
        case (true, false):
            path = selection.map { [$0] } ?? []
            selection = nil
        default:
            break
        }
    }

    /// Closes a conversation that is gone, and any opened from it.
    mutating func remove(where gone: (ChatLink) -> Bool) {
        if let selection, gone(selection) { self.selection = nil }
        if let index = path.firstIndex(where: gone) { path = Array(path[..<index]) }
    }

    /// The conversation open now: the one selected in two columns, or the one on top in one.
    var current: ChatLink? { selection ?? path.last }

    /// Opens the conversation `offset` rows after the open one, or before it when negative, in the list's `order`,
    /// as the keyboard's Next and Previous Conversation do. With none open, or one the list no longer shows, as
    /// while searching, it starts at the top of the list going down and at the bottom going up; at either end it stays.
    mutating func step(_ offset: Int, through order: [ChatLink], in layout: HomeLayout) {
        guard offset != 0, let first = order.first, let last = order.last else { return }
        let target: ChatLink
        if let current, let index = order.firstIndex(of: current) {
            target = order[min(max(index + offset, 0), order.count - 1)]
        } else {
            target = offset > 0 ? first : last
        }
        if target != current { open(target, in: layout) }
    }

    /// Closes the open conversation, as the keyboard's Close Conversation does: in two columns none is selected,
    /// and in one the conversation beneath, or the list, shows.
    mutating func close() {
        if selection != nil {
            selection = nil
        } else if !path.isEmpty {
            path.removeLast()
        }
    }
}

/// The width of the list's column on the left of two, and of the gap after it, where a crease is.
struct SplitColumns: Equatable {
    var list: CGFloat
    var gap: CGFloat = 0

    static let narrowest: CGFloat = 320, widest: CGFloat = 400

    /// The list takes about a third, as on the Mac. A crease down the middle of the screen, as on the unfolded
    /// iPhone Duo, divides them instead: the list on one side, the conversation on the other, nothing on the crease.
    /// `divisions` are the screen's regions that divide content, with their margins, across this width.
    static func layout(width: CGFloat, divisions: [CGRect] = []) -> SplitColumns {
        let crease = divisions.first { region in
            region.height > region.width && region.minX > width / 4 && region.maxX < width * 3 / 4
        }
        if let crease { return SplitColumns(list: crease.minX, gap: crease.width) }
        return SplitColumns(list: min(max(width * 0.36, narrowest), widest))
    }

    /// The regions dividing content in a view, such as a crease, from iOS 27.1.
    static func divisions(in proxy: GeometryProxy) -> [CGRect] {
        if #available(iOS 27.1, *) { return proxy.reservedRegions(kind: .division).map(\.frame) }
        return []
    }
}

/// How wide a message gets in a wide conversation, so its lines stay short enough to read.
enum ReadableWidth {
    static let bubble: CGFloat = 560
    /// The least room beside a message, on the side away from its author, as in Messages.
    static let sideRoom: CGFloat = 48

    /// The room beside a message in a row this wide: at least the usual, and enough to keep it readable.
    static func sideRoom(rowWidth: CGFloat) -> CGFloat { max(sideRoom, rowWidth - bubble) }

    /// The widest a screen's column of text and buttons gets on a wide screen, margins included: the largest
    /// iPhone's width, so the Pair button is as wide on iPad as there.
    static let column: CGFloat = 440

    /// How wide a screen's column of text and buttons may be in a window this size: the whole window on a phone,
    /// upright or on its side, and `column` on iPad and the unfolded iPhone Duo.
    static func column(in size: CGSize) -> CGFloat { HomeLayout.isWide(size) ? column : .infinity }
}

/// A screen's column of text and buttons, such as the Pair screen's, centred at a readable width on a wide screen.
/// On a phone it takes the whole width, as before.
struct ReadableColumn: ViewModifier {
    @State private var size = CGSize.zero

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: ReadableWidth.column(in: size))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { Color.clear.onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 } }
    }
}

/// The edge of the system's vertical bar, as on the iPhone Duo's cover screen, from iOS 27.1; nil elsewhere.
struct VerticalBarReader: ViewModifier {
    @Binding var edge: HorizontalEdge?

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.modifier(Reading(edge: $edge))
        } else {
            content
        }
    }

    @available(iOS 27.1, *)
    private struct Reading: ViewModifier {
        @Binding var edge: HorizontalEdge?
        @Environment(\.toolbarVerticalEdge) private var verticalEdge

        func body(content: Content) -> some View {
            content.onChange(of: verticalEdge, initial: true) { edge = verticalEdge }
        }
    }
}

extension View {
    /// Tells `edge` where the system's vertical bar is, or nil when there is none.
    func readingVerticalBar(_ edge: Binding<HorizontalEdge?>) -> some View { modifier(VerticalBarReader(edge: edge)) }

    /// Centres a short sheet's content in the sheet beside the system's vertical bar.
    func centredInSheet() -> some View { modifier(SheetCentring()) }

    /// Holds a screen's column of text and buttons to a readable width on a wide screen.
    func readableColumn() -> some View { modifier(ReadableColumn()) }

    /// A form, list or editor in a sheet: on iPad as wide as a form, rather than as large as a page, which
    /// stretches its rows. A phone's sheet always spans its screen, so it is unchanged there.
    func formSheetSizing() -> some View { presentationSizing(.form) }

    /// A short sheet of a few buttons: on iPad as wide as a form and only as tall as what it holds, since iPad
    /// leaves out the height a phone's sheet is given.
    func shortSheetSizing() -> some View { presentationSizing(.form.fitted(horizontal: false, vertical: true)) }
}

/// Beside the iPhone Duo's vertical bar a short sheet spans the screen, under the bar, but keeps the bar's
/// room as safe area on that side, so its content would sit off the middle of the sheet and its grabber.
/// There the content takes the sheet's whole width; elsewhere it keeps the safe area, clear of the Dynamic Island.
struct SheetCentring: ViewModifier {
    /// Where the vertical bar is; read from the system unless given.
    var verticalBar: HorizontalEdge??
    @State private var reading: HorizontalEdge?

    func body(content: Content) -> some View {
        content
            .ignoresSafeArea(.container, edges: Self.ignoredEdges(verticalBar: verticalBar ?? reading))
            .readingVerticalBar($reading)
    }

    static func ignoredEdges(verticalBar: HorizontalEdge?) -> Edge.Set { verticalBar == nil ? [] : .horizontal }
}

/// This phone or iPad, as a menu names it, such as Open on iPad.
@MainActor enum ThisDevice {
    /// Its picture: an iPad's for an iPad, otherwise a phone's.
    static func symbol(for idiom: UIUserInterfaceIdiom = UIDevice.current.userInterfaceIdiom) -> String {
        idiom == .pad ? "ipad" : "iphone"
    }
}
