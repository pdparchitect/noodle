import Foundation
import Testing
@testable import NoodleLaunchChecks

@Suite struct AppInstanceTests {
    @Test func onlyOneCopyHoldsTheLockUntilItLetsGo() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try #require(AppInstance.lock(in: folder))
        #expect(AppInstance.lock(in: folder) == nil, "a second copy got the lock")
        close(first)
        let next = try #require(AppInstance.lock(in: folder), "the lock stayed taken after the first copy quit")
        close(next)
    }

    @Test func onlyPlainLaunchesAreGuarded() {
        #expect(AppInstance.isGuarded(["/Applications/Noodle.app/Contents/MacOS/Noodle"]))
        // Noodle starts its companions in the background; they are still one copy each.
        #expect(AppInstance.isGuarded(["/Applications/Noodle Computer.app/Contents/MacOS/NoodleComputer", "--noodle-background"]))
        // Test runs and the messenger command run beside the app with their own data.
        #expect(!AppInstance.isGuarded(["/Applications/Noodle Browser.app/Contents/MacOS/NoodleBrowser", "--smoke-test"]))
        #expect(!AppInstance.isGuarded(["/Applications/Noodle.app/Contents/MacOS/Noodle", "messenger", "send"]))
    }
}
