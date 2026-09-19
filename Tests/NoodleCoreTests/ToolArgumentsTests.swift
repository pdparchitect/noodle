import XCTest
@testable import NoodleCore

final class ToolArgumentsTests: XCTestCase {
    private let schema = Data("""
    {"type":"object","properties":{
      "selector":{"type":"string"},"count":{"type":"integer"},"scale":{"type":"number"},
      "fullPage":{"type":"boolean"},"max_results":{"type":"integer"},
      "languages":{"type":"array","items":{"type":"string"}},"options":{"type":"object"},"anything":{}}}
    """.utf8)

    private func build(_ flags: [String]) throws -> NSDictionary {
        try JSONSerialization.jsonObject(with: ToolArguments.build(flags, schema: schema)) as! NSDictionary
    }

    func testFlagsBecomeTypedSchemaProperties() throws {
        XCTAssertEqual(try build([]), [:])
        XCTAssertEqual(try build(["--selector", "#a > b", "--count", "2", "--scale", "1.5", "--fullPage"]),
                       ["selector": "#a > b", "count": 2, "scale": 1.5, "fullPage": true])
        XCTAssertEqual(try build(["--fullPage", "false", "--selector", "--not-a-flag"]), ["fullPage": false, "selector": "--not-a-flag"])
        XCTAssertEqual(try build(["--languages", "en", "--languages", "bg"]), ["languages": ["en", "bg"]])
        XCTAssertEqual(try build(["--languages", #"["en","de"]"#, "--options", #"{"a":1}"#]), ["languages": ["en", "de"], "options": ["a": 1]])
        XCTAssertEqual(try build(["--anything", "text"]), ["anything": "text"])
    }

    func testKebabCaseNamesReachSnakeAndCamelCaseProperties() throws {
        XCTAssertEqual(try build(["--max-results", "5", "--full-page"]), ["max_results": 5, "fullPage": true])
    }

    func testInputSeedsTheObjectAndFlagsOverrideIt() throws {
        XCTAssertEqual(try build(["--input", #"{"selector":"a","nested":{"x":[1]}}"#, "--selector", "b"]),
                       ["selector": "b", "nested": ["x": [1]]])
    }

    func testInvalidFlagsAreRejectedWithTheValidNames() throws {
        XCTAssertThrowsError(try build(["--unknown", "1"])) { XCTAssertTrue($0.localizedDescription.contains("--selector")) }
        for flags in [["selector", "a"], ["--count", "two"], ["--count", "1.5"], ["--scale", "big"], ["--fullPage", "maybe", "x"],
                      ["--selector"], ["--selector", "a", "--selector", "b"], ["--options", "[1]"], ["--input", "[1]"],
                      ["--input", "{}", "--input", "{}"], ["--count"]] {
            XCTAssertThrowsError(try build(flags), flags.joined(separator: " "))
        }
    }

    func testSchemaWithoutPropertiesAcceptsOnlyInput() throws {
        let open = Data(#"{"type":"object"}"#.utf8)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: ToolArguments.build(["--input", #"{"a":1}"#], schema: open)) as? NSDictionary, ["a": 1])
        XCTAssertThrowsError(try ToolArguments.build(["--a", "1"], schema: open))
    }
}
