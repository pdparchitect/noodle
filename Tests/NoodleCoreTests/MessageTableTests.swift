import XCTest
@testable import NoodleCore

final class MessageTableTests: XCTestCase {
    private let plans = """
        Here's the comparison:

        | Plan | Seats | Price | Notes |
        |:-----|------:|:-----:|-------|
        | Starter | 3 | $12 | Email \\| chat |
        | **Team** | 25 | $89 | [details](https://example.com) |

        **Team** fits best.
        """

    func testMessageSplitsAroundTablesAndKeepsTheirLayout() throws {
        let segments = MessageSegment.split(plans)
        XCTAssertEqual(segments.count, 3)
        XCTAssertEqual(segments.first, .text("Here's the comparison:"))
        XCTAssertEqual(segments.last, .text("**Team** fits best."))
        guard case .table(let table) = segments[1] else { return XCTFail("No table in \(segments)") }
        XCTAssertEqual(table.header, ["Plan", "Seats", "Price", "Notes"])
        XCTAssertEqual(table.alignments, [.leading, .trailing, .center, .automatic])
        XCTAssertEqual(table.rows, [["Starter", "3", "$12", "Email | chat"],
                                    ["**Team**", "25", "$89", "[details](https://example.com)"]])
    }

    func testOrdinaryMessagesStayOneUntouchedText() {
        for body in ["A short reply.", "  Spaced\n\n  out  ", "a | b", "a | b\nnot a separator",
                     "| A | B |\n|---|", "- one\n- two", ""] {
            XCTAssertEqual(MessageSegment.split(body), body.isEmpty ? [] : [.text(body)], body)
        }
    }

    func testTablesInsideCodeFencesStayText() {
        let body = "Raw Markdown:\n```\n| A | B |\n|---|---|\n| 1 | 2 |\n```"
        XCTAssertEqual(MessageSegment.split(body), [.text(body)])
    }

    func testRaggedRowsMatchTheHeaderAndTablesCanOpenOrCloseAMessage() throws {
        let segments = MessageSegment.split("A | B\n--|--\n1 |\n1 | 2 | 3")
        XCTAssertEqual(segments, [.table(MessageTable(header: ["A", "B"], alignments: [.automatic, .automatic],
                                                       rows: [["1", ""], ["1", "2"]]))])
    }

    func testNumberColumnsAlignTrailingUnlessTheAgentChose() throws {
        let table = MessageTable(header: ["Name", "Cost", "Count", "Fixed"], alignments: [.automatic, .automatic, .automatic, .center],
                                 rows: [["Ann", "$1,204.50", "12", "3"], ["Bo", "+55%", "", "4"]])
        XCTAssertEqual((0..<4).map(table.alignment), [.leading, .trailing, .trailing, .center])
    }

    func testSortingComparesNumbersAsNumbersAndTextInFinderOrder() throws {
        let table = MessageTable(header: ["Day", "Cost"], alignments: [.automatic, .automatic],
                                 rows: [["Sep 15", "$1,204"], ["Sep 2", "Custom"], ["**Sep 10**", "$89"], ["Sep 1", "$300.5"]])
        XCTAssertEqual(table.sorted(by: .init(column: 1, ascending: true)).rows.map { $0[0] },
                       ["**Sep 10**", "Sep 1", "Sep 15", "Sep 2"])
        XCTAssertEqual(table.sorted(by: .init(column: 1, ascending: false)).rows.map { $0[0] },
                       ["Sep 2", "Sep 15", "Sep 1", "**Sep 10**"])
        XCTAssertEqual(table.sorted(by: .init(column: 0, ascending: true)).rows.map { $0[0] },
                       ["Sep 1", "Sep 2", "**Sep 10**", "Sep 15"])
        XCTAssertEqual(table.sorted(by: nil), table)
        XCTAssertEqual(table.rowOrder(by: .init(column: 1, ascending: true)), [2, 3, 0, 1])
    }

    func testHeaderClicksCycleAscendingDescendingAndOriginalOrder() {
        let ascending = MessageTableSort.next(after: nil, column: 2)
        XCTAssertEqual(ascending, .init(column: 2, ascending: true))
        XCTAssertEqual(MessageTableSort.next(after: ascending, column: 2), .init(column: 2, ascending: false))
        XCTAssertNil(MessageTableSort.next(after: .init(column: 2, ascending: false), column: 2))
        XCTAssertEqual(MessageTableSort.next(after: ascending, column: 0), .init(column: 0, ascending: true))
    }

    func testCSVHoldsTheShownTextAndQuotesWhereNeeded() throws {
        guard case .table(let table) = MessageSegment.split(plans)[1] else { return XCTFail() }
        XCTAssertEqual(table.csv, "Plan,Seats,Price,Notes\nStarter,3,$12,Email | chat\nTeam,25,$89,details\n")
        let tricky = MessageTable(header: ["A", "B"], alignments: [.automatic, .automatic],
                                  rows: [["1,5", "say \"hi\""], ["`x`", "é"]])
        XCTAssertEqual(tricky.csv, "A,B\n\"1,5\",\"say \"\"hi\"\"\"\nx,é\n")
        XCTAssertEqual(tricky.sorted(by: .init(column: 0, ascending: false)).csv, "A,B\nx,é\n\"1,5\",\"say \"\"hi\"\"\"\n")
    }

    func testOnlyLongTablesFoldAndTheyHideAtLeastThreeRows() {
        func table(_ count: Int) -> MessageTable {
            MessageTable(header: ["N"], alignments: [.automatic], rows: (0..<count).map { ["\($0)"] })
        }
        XCTAssertEqual(MessageTable.foldedRowCount, 6)
        XCTAssertFalse(table(8).folds)
        XCTAssertTrue(table(9).folds)
    }
}
