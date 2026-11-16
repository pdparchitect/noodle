import Foundation
import XCTest
@testable import Noodle

/// Attach File… and Choose Photo…, in every app: what is picked goes to the conversation the picker was opened for,
/// once, even when another conversation shows by the time it closes.
final class AttachmentPickersTests: XCTestCase {
    func testPickedFilesGoWhereThePickerWasOpened() {
        let opened = UUID()
        var pickers = AttachmentPickers()
        pickers.attachFile(to: opened)
        XCTAssertTrue(pickers.choosingFiles)
        XCTAssertEqual(pickers.takeDestination(), opened)
        XCTAssertNil(pickers.takeDestination(), "Taken once")

        pickers.choosePhoto(for: opened)
        XCTAssertTrue(pickers.choosingPhotos)
        XCTAssertTrue(pickers.photos.isEmpty)
        XCTAssertEqual(pickers.takeDestination(), opened)
    }
}
