import Foundation
import ApplicationServices

/// Resolve only explicit accessibility ownership. Main-window fallback is for
/// transient dialogs/panels; a normal document must never jump to another one.
public enum LocalMacWindowRoot {
    public struct Node<Element> {
        public var pid: Int32
        public var isWindow: Bool
        public var isTransient: Bool
        public var parent: Element?
        public var window: Element?
        public init(pid: Int32, isWindow: Bool, isTransient: Bool = false,
                    parent: Element? = nil, window: Element? = nil) {
            self.pid = pid; self.isWindow = isWindow; self.isTransient = isTransient
            self.parent = parent; self.window = window
        }
        public init(pid: Int32, role: String, subrole: String, modal: Bool,
                    parent: Element? = nil, window: Element? = nil) {
            let isWindow = [kAXWindowRole, kAXSheetRole, kAXDrawerRole, kAXPopoverRole].contains(role)
            // An AXWindow with an unknown subrole can be an app's floating
            // bubble. Only standard windows qualify as independent roots.
            self.init(pid: pid, isWindow: isWindow,
                      isTransient: isWindow && (role != kAXWindowRole || subrole != kAXStandardWindowSubrole || modal),
                      parent: parent, window: window)
        }
    }
    public struct Selection<Element> {
        public var root: Element
        public var windows: [Element]
    }
    /// Inventory only verified, non-transient roots. Sheets and floating UI
    /// enrich their owner's family, never become additional inventory entries.
    public static func families<Element, Window>(elements: [Element], pid: Int32, mainWindow: Element?,
                                                  same: (Element, Element) -> Bool,
                                                  read: (Element) -> Node<Element>?,
                                                  match: (Element) -> Window?,
                                                  sameWindow: (Window, Window) -> Bool) -> [Selection<Window>] {
        var families: [Selection<Window>] = []
        for element in elements {
            guard let selection = resolve(focused: element, pid: pid, mainWindow: mainWindow, same: same, read: read),
                  let node = read(selection.root), node.isWindow, !node.isTransient, node.pid == pid,
                  let root = match(selection.root) else { continue }
            let members = selection.windows.compactMap(match)
            if let index = families.firstIndex(where: { sameWindow($0.root, root) }) {
                for member in members where !families[index].windows.contains(where: { sameWindow($0, member) }) {
                    families[index].windows.append(member)
                }
            } else {
                families.append(.init(root: root, windows: [root] + members.filter { !sameWindow($0, root) }))
            }
        }
        return families
    }
    /// Hierarchy lookup enriches an independently verified focused window. An
    /// unreadable ancestor or an unmatched root must not remove that fallback.
    /// `match` must verify each element against the same process/display.
    public static func capture<Element, Window>(focused: Element, selection: Selection<Element>?,
                                               same: (Element, Element) -> Bool,
                                               match: (Element) -> Window?) -> Selection<Window>? {
        var elements: [Element] = []
        let preferred = selection.map { [$0.root] + $0.windows.reversed() } ?? []
        for element in preferred + [focused] where !elements.contains(where: { same($0, element) }) {
            elements.append(element)
        }
        let windows = elements.compactMap(match)
        guard let root = windows.first else { return nil }
        return .init(root: root, windows: windows)
    }
    public static func resolve<Element>(focused: Element, pid: Int32, mainWindow: @autoclosure () -> Element?,
                                        same: (Element, Element) -> Bool,
                                        read: (Element) -> Node<Element>?) -> Selection<Element>? {
        func ascend(_ start: Element) -> [(Element, Node<Element>)]? {
            var current = start, visited: [Element] = [], windows: [(Element, Node<Element>)] = []
            for _ in 0..<32 {
                guard !visited.contains(where: { same($0, current) }),
                      let node = read(current), node.pid == pid else { return nil }
                visited.append(current)
                if node.isWindow { windows.append((current, node)) }
                // AXWindow skips intermediate controls/sheets to their owner.
                // A window commonly refers to itself; then walk AXParent.
                if let owner = node.window, !same(owner, current) { current = owner }
                else if let parent = node.parent { current = parent }
                else { return windows }
            }
            return nil
        }
        guard var windows = ascend(focused), let highest = windows.last else { return nil }
        var root = highest.0
        if highest.1.isTransient, let mainWindow = mainWindow(), !same(mainWindow, root),
           let main = ascend(mainWindow), let owner = main.last, !owner.1.isTransient {
            root = owner.0
            for entry in main where !windows.contains(where: { same($0.0, entry.0) }) { windows.append(entry) }
        }
        return Selection(root: root, windows: windows.map(\.0))
    }
}
