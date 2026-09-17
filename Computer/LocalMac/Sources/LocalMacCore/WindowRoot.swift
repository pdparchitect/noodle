import Foundation

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
    }
    public struct Selection<Element> {
        public var root: Element
        public var windows: [Element]
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
