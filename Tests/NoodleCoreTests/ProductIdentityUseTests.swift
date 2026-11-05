import Foundation
import ProductIdentity
import XCTest
@testable import NoodleCore

/// Code that more than one product shares names that product, never Noodle by heart, and Noodle's
/// own identifiers stay exactly as they were.
final class ProductIdentityUseTests: XCTestCase {
    func testNoodleKeepsItsIdentifiersAndFolders() {
        XCTAssertEqual(ProductIdentity.current, .noodle, "Tests run as Noodle")
        XCTAssertEqual(RuntimeDiagnostics.subsystem, "com.pdparchitect.noodle.runtime")
        let support = URL(fileURLWithPath: "/tmp/Application Support", isDirectory: true)
        XCTAssertEqual(HarnessStorage.dataRoot(applicationSupport: support).lastPathComponent, "Noodle")
    }

    /// The places that may name Noodle's identifiers: the product list itself, Noodle Computer's channel
    /// table, and the Google sign-in clients registered for Noodle's apps.
    private static let allowed = [
        "Shared/Product/Sources/ProductIdentity/ProductIdentity.swift",
        "Computer/Bridge/Sources/ComputerBridge/BuildIdentity.swift",
        "Sources/NoodleCore/ToolOAuthConfigurations.swift",
    ]

    func testSharedCodeNamesNoNoodleIdentifier() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let shared = ["Sources/NoodleCore", "Sources/NoodleRuntime", "Sources/NoodleAgentBridge", "Sources/NoodleAgentHost",
                      "Sources/NoodleMCP", "Computer/Sources/ComputerEngine", "Computer/Bridge/Sources/ComputerBridge",
                      "Shared/Product/Sources"]
        var found: [String] = []
        for folder in shared {
            guard let files = FileManager.default.enumerator(at: repository.appendingPathComponent(folder), includingPropertiesForKeys: nil) else {
                return XCTFail("Missing \(folder)")
            }
            for case let file as URL in files where file.pathExtension == "swift" {
                let path = String(file.path.dropFirst(repository.path.count + 1))
                guard !Self.allowed.contains(path) else { continue }
                for (number, line) in try String(contentsOf: file, encoding: .utf8).components(separatedBy: .newlines).enumerated()
                where line.contains("com.pdparchitect.noodle") && !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") {
                    found.append("\(path):\(number + 1)")
                }
            }
        }
        XCTAssertEqual(found, [], "Derive these from ProductIdentity")
    }
}
