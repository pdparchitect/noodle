import XCTest
@testable import AppletCore

final class WindowTests: XCTestCase {
    func decode(_ text: String) throws -> NoodletWindowOptions { try JSONDecoder().decode(NoodletWindowOptions.self, from: Data(text.utf8)) }
    func testWindowCompatibilityAndInvalidBounds() throws {
        let defaults = try decode("{}")
        XCTAssertEqual(defaults.type, .standard)
        XCTAssertTrue(defaults.resizable)
        XCTAssertFalse(defaults.rememberFrame)
        XCTAssertEqual(defaults.size(), CGSize(width:900,height:620))
        for text in [#"{"type":"unknown"}"#, #"{"background":"unknown"}"#, #"{"width":119}"#, #"{"minWidth":500,"maxWidth":400}"#, #"{"height":700,"maxHeight":500}"#] {
            XCTAssertThrowsError(try decode(text).validate())
        }
        let options = try decode(#"{"type":"floating","background":"translucent","resizable":false,"rememberFrame":true,"width":320,"height":350,"minWidth":260,"maxWidth":480}"#)
        try options.validate()
        XCTAssertEqual(options.size(width:200).width, 260)
        XCTAssertEqual(options.size(width:900).width, 480)
        XCTAssertEqual(try JSONDecoder().decode(NoodletWindowOptions.self, from: JSONEncoder().encode(options)).background, .translucent)
    }
}
