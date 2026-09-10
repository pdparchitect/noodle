import XCTest
@testable import ComputerCore

final class ContainerRegistryTests: XCTestCase {
    private func catalogue() throws -> [String: Any] {
        ["schemaVersion": 1, "defaultTemplateID": "desktop",
         "templates": try ContainerRegistry.bundled.templates.map {
             try JSONSerialization.jsonObject(with: JSONEncoder().encode($0))
         }]
    }

    private func load(_ catalogue: [String: Any]) throws -> ContainerRegistry {
        try ContainerRegistry(data: JSONSerialization.data(withJSONObject: catalogue))
    }

    func testAdditionalTemplateAndDefaultAreDataDriven() throws {
        var catalogue = try catalogue()
        var templates = try XCTUnwrap(catalogue["templates"] as? [[String: Any]])
        var extra = templates[0]
        extra["id"] = "creative"
        extra["name"] = "Creative"
        extra["description"] = "A space for your ideas."
        extra["defaultName"] = "My Studio"
        extra["imageReference"] = "example.com/creative:latest"
        extra["defaultCPUs"] = 6
        extra["defaultMemoryGiB"] = 8
        extra["defaultDiskGiB"] = 64
        templates.append(extra)
        catalogue["templates"] = templates
        catalogue["defaultTemplateID"] = "creative"
        let registry = try load(catalogue)
        XCTAssertEqual(registry.templates.map(\.id), ["desktop", "shell", "creative"])
        let template = registry.defaultTemplate
        XCTAssertEqual(template.name, "Creative")
        XCTAssertEqual(template.description, "A space for your ideas.")
        XCTAssertEqual(template.type, .desktop)
        let computer = template.makeComputer()
        XCTAssertEqual(computer.name, "My Studio")
        XCTAssertEqual(computer.cpuCount, 6)
        XCTAssertEqual(computer.memoryGiB, 8)
        XCTAssertEqual(computer.diskGiB, 64)
        XCTAssertEqual(registry.template(for: computer), template)
        var custom = computer
        custom.customImage = true
        XCTAssertNil(registry.template(for: custom))
    }

    func testInvalidCatalogueIsRejected() throws {
        let original = try catalogue()
        for (key, value) in [("schemaVersion", 2 as Any), ("defaultTemplateID", "missing" as Any),
                             ("templates", [] as Any)] {
            var invalid = original
            invalid[key] = value
            XCTAssertThrowsError(try load(invalid), key)
        }
        let templates = try XCTUnwrap(original["templates"] as? [[String: Any]])
        var duplicate = original
        duplicate["templates"] = templates + [templates[0]]
        XCTAssertThrowsError(try load(duplicate))
        for (key, value) in [("name", "" as Any), ("type", "unknown" as Any),
                             ("imageReference", templates[1]["imageReference"]!),
                             ("defaultCPUs", 0 as Any), ("minimumMemoryGiB", 65 as Any),
                             ("defaultMemoryGiB", 1 as Any), ("minimumDiskGiB", 513 as Any),
                             ("defaultDiskGiB", 4 as Any), ("requiresNetworking", false as Any)] {
            var invalid = original
            var entries = templates
            entries[0][key] = value
            invalid["templates"] = entries
            XCTAssertThrowsError(try load(invalid), key)
        }
    }
}
