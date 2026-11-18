@testable import NoodleRuntimeSettings
import XCTest

final class ToolSetupStepsTests: XCTestCase {
    func testCopiedStepsAreNumberedPlainTextWithEachLinkWrittenOut() {
        let steps = ["Open the [Google Cloud console](https://console.cloud.google.com) and enable the **Admin SDK API**.",
                     "Copy the `Client ID` here.", "Visit <https://example.com>."]
        XCTAssertEqual(ToolSetupSteps.plainText(steps), """
            1. Open the Google Cloud console (https://console.cloud.google.com) and enable the Admin SDK API.
            2. Copy the Client ID here.
            3. Visit https://example.com.
            """)
    }
}
