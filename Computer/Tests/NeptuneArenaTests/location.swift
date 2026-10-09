import Foundation
@main struct LocationTest {
    static func main() {
        do {
            let location = try RendererLocation(executable: URL(fileURLWithPath: CommandLine.arguments[0]))
            guard location.group == "noodle-test", location.frameworks.hasSuffix("Metadata.app/Contents/Frameworks/neptune") else { exit(1) }
            print("PASS: renderer reads its enclosing app metadata despite its own background-only Info.plist")
        } catch { print("FAIL: renderer cannot locate the enclosing app group: \(error)"); exit(1) }
    }
}
