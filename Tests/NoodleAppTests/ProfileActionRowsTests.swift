import Testing
@testable import Noodle

struct ProfileActionRowsTests {
    @Test func fourOrFewerActionsStayOnOneRow() {
        #expect(AgentProfileSheet.rows(Array(1...4)) == [[1, 2, 3, 4]])
        #expect(AgentProfileSheet.rows(Array(1...2)) == [[1, 2]])
    }

    @Test func moreActionsWrapIntoEvenRowsOfAtMostFour() {
        #expect(AgentProfileSheet.rows(Array(1...5)) == [[1, 2, 3], [4, 5]])
        #expect(AgentProfileSheet.rows(Array(1...6)) == [[1, 2, 3], [4, 5, 6]])
        #expect(AgentProfileSheet.rows(Array(1...7)) == [[1, 2, 3, 4], [5, 6, 7]])
    }
}
