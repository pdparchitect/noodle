import XCTest
@testable import LocalMacCore

final class WindowRootTests: XCTestCase {
    typealias Node = LocalMacWindowRoot.Node<Int>
    private func resolve(_ focused: Int, main: Int? = nil, nodes: [Int: Node]) -> LocalMacWindowRoot.Selection<Int>? {
        LocalMacWindowRoot.resolve(focused: focused, pid: 50, mainWindow: main, same: ==) { nodes[$0] }
    }
    func testUnknownWindowBubbleIsAttachedWithoutBecomingAnotherRoot() {
        let nodes: [Int: Node] = [
            1: .init(pid: 50, role: "AXWindow", subrole: "AXStandardWindow", modal: false),
            2: .init(pid: 50, role: "AXWindow", subrole: "AXStandardWindow", modal: false),
            3: .init(pid: 50, role: "AXWindow", subrole: "AXUnknown", modal: false),
            4: .init(pid: 50, role: "AXSheet", subrole: "", modal: true, parent: 2)
        ]
        let families = LocalMacWindowRoot.families(elements: [3, 1, 2, 4], pid: 50, mainWindow: 1,
            same: ==, read: { nodes[$0] }, match: { $0 }, sameWindow: ==)
        XCTAssertEqual(families.map(\.root), [1, 2])
        XCTAssertEqual(Set(families[0].windows), [1, 3])
        XCTAssertEqual(Set(families[1].windows), [2, 4])
        let unowned = LocalMacWindowRoot.families(elements: [3], pid: 50, mainWindow: nil,
            same: ==, read: { nodes[$0] }, match: { $0 }, sameWindow: ==)
        XCTAssertTrue(unowned.isEmpty)
    }
    func testVisibleInventoryGroupsSheetsAndExcludesUnownedFloatingUI() throws {
        let nodes: [Int: Node] = [
            1: .init(pid: 50, isWindow: true, parent: 9),
            2: .init(pid: 50, isWindow: true, parent: 9),
            3: .init(pid: 50, isWindow: true, isTransient: true, parent: 1),
            4: .init(pid: 50, isWindow: true, isTransient: true, window: 3),
            5: .init(pid: 50, isWindow: true, isTransient: true),
            6: .init(pid: 99, isWindow: true),
            7: .init(pid: 50, isWindow: false, parent: 9),
            9: .init(pid: 50, isWindow: false)
        ]
        let families = LocalMacWindowRoot.families(elements: [3, 2, 1, 4, 5, 6, 7, 1], pid: 50,
            mainWindow: nil, same: ==, read: { nodes[$0] }, match: { $0 == 7 || $0 == 9 ? nil : $0 }, sameWindow: ==)
        XCTAssertEqual(families.map(\.root), [1, 2])
        XCTAssertEqual(Set(families[0].windows), [1, 3, 4])
        XCTAssertEqual(families[1].windows, [2])
        let closedRoot = LocalMacWindowRoot.families(elements: [3, 4], pid: 50, mainWindow: nil,
            same: ==, read: { nodes[$0] }, match: { $0 == 1 ? nil : $0 }, sameWindow: ==)
        XCTAssertTrue(closedRoot.isEmpty, "A sheet cannot become a root when its parent is missing")
    }
    func testInventoryAssociatesAppModalDialogWithoutMergingDocuments() {
        let nodes: [Int: Node] = [
            1: .init(pid: 50, isWindow: true), 2: .init(pid: 50, isWindow: true),
            3: .init(pid: 50, isWindow: true, isTransient: true)
        ]
        let families = LocalMacWindowRoot.families(elements: [1, 2, 3], pid: 50, mainWindow: 2,
            same: ==, read: { nodes[$0] }, match: { $0 }, sameWindow: ==)
        XCTAssertEqual(families.map(\.root), [1, 2])
        XCTAssertEqual(families[0].windows, [1])
        XCTAssertEqual(Set(families[1].windows), [2, 3])
    }
    func testSheetWalksThroughNestedParentsToDocumentRoot() throws {
        let nodes: [Int: Node] = [
            1: .init(pid: 50, isWindow: true, isTransient: true, parent: 2),
            2: .init(pid: 50, isWindow: true, isTransient: true, parent: 3),
            3: .init(pid: 50, isWindow: true, parent: 4),
            4: .init(pid: 50, isWindow: false)
        ]
        let result = try XCTUnwrap(resolve(1, nodes: nodes))
        XCTAssertEqual(result.root, 3)
        XCTAssertEqual(result.windows, [1, 2, 3])
        // Dismissing the popup changes composition, not the preview's root.
        XCTAssertEqual(resolve(3, nodes: nodes)?.root, result.root)
    }
    func testOwnerWindowSkipsControlsAndSelfWindowReferenceIsNormal() throws {
        let nodes: [Int: Node] = [
            1: .init(pid: 50, isWindow: true, isTransient: true, parent: 2, window: 3),
            2: .init(pid: 50, isWindow: false, parent: 3),
            3: .init(pid: 50, isWindow: true, parent: 4, window: 3),
            4: .init(pid: 50, isWindow: false)
        ]
        let result = try XCTUnwrap(resolve(1, nodes: nodes))
        XCTAssertEqual(result.root, 3)
        XCTAssertEqual(result.windows, [1, 3])
    }
    func testAppModalDialogIncludesItsMainWindowButDoesNotMergeDocuments() throws {
        let nodes: [Int: Node] = [
            1: .init(pid: 50, isWindow: true, isTransient: true, parent: 4),
            2: .init(pid: 50, isWindow: true, parent: 4),
            3: .init(pid: 50, isWindow: true, parent: 4),
            4: .init(pid: 50, isWindow: false)
        ]
        let dialog = try XCTUnwrap(resolve(1, main: 2, nodes: nodes))
        XCTAssertEqual(dialog.root, 2)
        XCTAssertEqual(dialog.windows, [1, 2])
        let document = try XCTUnwrap(resolve(3, main: 2, nodes: nodes))
        XCTAssertEqual(document.root, 3)
        XCTAssertEqual(document.windows, [3])
        XCTAssertEqual(resolve(1, nodes: nodes)?.root, 1) // Standalone dialog, no owner.
    }
    func testRejectsCyclesExcessiveDepthMissingNodesAndCrossProcessParents() {
        XCTAssertNil(resolve(1, nodes: [1: .init(pid: 50, isWindow: true, parent: 1)]))
        XCTAssertNil(resolve(1, nodes: [1: .init(pid: 50, isWindow: true, parent: 2), 2: .init(pid: 50, isWindow: false, parent: 1)]))
        XCTAssertNil(resolve(1, nodes: [1: .init(pid: 50, isWindow: true, parent: 2)]))
        XCTAssertNil(resolve(1, nodes: [1: .init(pid: 50, isWindow: true, parent: 2), 2: .init(pid: 99, isWindow: true)]))
        let nodes = Dictionary(uniqueKeysWithValues: (1...40).map { ($0, Node(pid: 50, isWindow: true, parent: $0 + 1)) })
        var reads = 0
        XCTAssertNil(LocalMacWindowRoot.resolve(focused: 1, pid: 50, mainWindow: nil, same: ==) { reads += 1; return nodes[$0] })
        XCTAssertEqual(reads, 32)
    }
    func testMainFallbackCannotIncludeAnotherProcessOrAnotherDialog() {
        let dialog = Node(pid: 50, isWindow: true, isTransient: true)
        for other in [Node(pid: 99, isWindow: true), Node(pid: 50, isWindow: true, isTransient: true)] {
            let result = resolve(1, main: 2, nodes: [1: dialog, 2: other])
            XCTAssertEqual(result?.root, 1)
            XCTAssertEqual(result?.windows, [1])
        }
    }
    func testUnavailableAncestryKeepsVerifiedFocusedWindowAvailable() throws {
        // An unsupported role, missing application ancestor, or lookup timeout
        // used to erase a window that the old geometry/PID lookup could capture.
        for nodes: [Int: Node] in [[:], [1: .init(pid: 50, isWindow: true, parent: 2)]] {
            let selection = resolve(1, nodes: nodes)
            XCTAssertNil(selection)
            let capture = try XCTUnwrap(LocalMacWindowRoot.capture(focused: 1, selection: selection, same: ==) {
                $0 == 1 ? "verified focus" : nil
            })
            XCTAssertEqual(capture.root, "verified focus")
            XCTAssertEqual(capture.windows, ["verified focus"])
        }
    }
    func testOrdinaryWindowDoesNotAskForAnUnneededMainWindow() {
        var reads = 0
        func main() -> Int? { reads += 1; return nil }
        let selection = LocalMacWindowRoot.resolve(focused: 1, pid: 50, mainWindow: main(), same: ==) {
            _ in Node(pid: 50, isWindow: true)
        }
        XCTAssertEqual(selection?.root, 1)
        XCTAssertEqual(reads, 0)
    }
    func testUnmatchedRootFallsBackButMatchedRootKeepsItsDialog() throws {
        let selection = resolve(1, nodes: [
            1: .init(pid: 50, isWindow: true, isTransient: true, parent: 2),
            2: .init(pid: 50, isWindow: true)
        ])
        let fallback = try XCTUnwrap(LocalMacWindowRoot.capture(focused: 1, selection: selection, same: ==) {
            $0 == 1 ? 101 : nil
        })
        XCTAssertEqual(fallback.root, 101)
        XCTAssertEqual(fallback.windows, [101])
        let family = try XCTUnwrap(LocalMacWindowRoot.capture(focused: 1, selection: selection, same: ==) { $0 + 100 })
        XCTAssertEqual(family.root, 102)
        XCTAssertEqual(family.windows, [102, 101])
        XCTAssertNil(LocalMacWindowRoot.capture(focused: 1, selection: selection, same: ==) { _ -> Int? in nil })
    }
}
