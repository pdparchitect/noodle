import Testing
import NoodleRuntimeSettings
@testable import Noodle

struct ProfileActionRowsTests {
    @Test func fourOrFewerActionsStayOnOneRow() {
        #expect(ProfileActionRows.split(Array(1...4)) == [[1, 2, 3, 4]])
        #expect(ProfileActionRows.split(Array(1...2)) == [[1, 2]])
    }

    @Test func moreActionsWrapIntoEvenRowsOfAtMostFour() {
        #expect(ProfileActionRows.split(Array(1...5)) == [[1, 2, 3], [4, 5]])
        #expect(ProfileActionRows.split(Array(1...6)) == [[1, 2, 3], [4, 5, 6]])
        #expect(ProfileActionRows.split(Array(1...7)) == [[1, 2, 3, 4], [5, 6, 7]])
    }
}
