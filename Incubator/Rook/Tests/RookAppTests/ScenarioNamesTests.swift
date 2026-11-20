import Foundation
import NoodleBrand
import XCTest

final class ScenarioNamesTests: XCTestCase {
    func testScenarioAgentsUseConsistentGeneratedNamesAndMatchingMentions() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folders = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Scenarios"), includingPropertiesForKeys: nil)
        var namesByKey: [String: String] = [:]
        for folder in folders {
            let file = folder.appendingPathComponent("scenario.json")
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let data = try Data(contentsOf: file)
            let scenario = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let agents = try XCTUnwrap(scenario["agents"] as? [[String: Any]])
            var names = Set<String>()
            for agent in agents {
                let key = try XCTUnwrap(agent["key"] as? String), name = try XCTUnwrap(agent["name"] as? String)
                XCTAssertEqual(name.split(separator: " ").count, 2, "\(folder.lastPathComponent): \(name) should be a generated name")
                XCTAssertTrue(BotNameGenerator.presentation(of: name) != nil, "\(name) should come from Noodle's generator")
                if let previous = namesByKey[key] { XCTAssertEqual(name, previous) }
                namesByKey[key] = name
                XCTAssertTrue(names.insert(name).inserted)
            }
            let champion = (scenario["champion"] as? String) ?? ""
            let allowed = names.union([champion, champion.components(separatedBy: " ").first ?? ""])
            func checkMentions(_ value: Any) {
                if let object = value as? [String: Any] { object.values.forEach(checkMentions) }
                else if let array = value as? [Any] { array.forEach(checkMentions) }
                else if let text = value as? String {
                    let regex = try! NSRegularExpression(pattern: "@[A-Z][A-Za-z]*(?: [A-Z][A-Za-z]*)?")
                    for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                        guard let range = Range(match.range, in: text) else { continue }
                        let mention = String(text[range].dropFirst())
                        XCTAssertTrue(allowed.contains(mention), "\(folder.lastPathComponent): unknown mention @\(mention)")
                    }
                }
            }
            checkMentions(scenario)
        }
        XCTAssertFalse(namesByKey.isEmpty)
    }
}
