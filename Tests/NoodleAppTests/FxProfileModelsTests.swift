import Foundation
import NoodleCore
import XCTest
@testable import NoodleRuntime

/// Each FX login sends model requests through its own Vercel team, so a bot on a profile is offered
/// that team's models, not the Default login's.
@MainActor final class FxProfileModelsTests: XCTestCase {
    private func model(_ id: String) -> HarnessModel {
        HarnessModel(id: id, displayName: id, description: "", supportedEfforts: [], defaultEffort: "", isDefault: false)
    }

    func testAProfileOffersItsOwnTeamsModels() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fx-profile-models-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let fx = root.appendingPathComponent(".local/bin/fx")
        try FileManager.default.createDirectory(at: fx.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: fx)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fx.path)
        let suite = "fx-profile-models-\(UUID())"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let runtime = AgentRuntimeCoordinator(discovery: HarnessDiscovery(homeDirectory: root, applicationsDirectory: root,
            executableSearchDirectories: [], applicationBundleURL: root, environment: [:]), defaults: UserDefaults(suiteName: suite)!)
        let profiles = HarnessProfileStore(root: root.appendingPathComponent("library"))
        runtime.harnessProfiles = profiles
        let work = try profiles.create(provider: .fx, named: "Work")

        var team = ["zai/glm-5.3"]
        var asked: [(UUID, String)] = []
        runtime.loadFxProfileModels = { profile, path in
            asked.append((profile, path))
            return team.map(self.model)
        }
        XCTAssertTrue(runtime.models(for: "fx", profile: work.id).isEmpty, "Nothing is offered before the list is read")
        runtime.refreshFxModels(profile: work.id)
        try await waitUntil { runtime.fxProfileModels[work.id] != nil }
        XCTAssertEqual(asked.first?.0, work.id)
        XCTAssertEqual(asked.first?.1, fx.path)
        XCTAssertEqual(runtime.models(for: "fx", profile: work.id).map(\.id), ["zai/glm-5.3"])
        XCTAssertEqual(runtime.models(for: "fx", profile: nil).map(\.id), runtime.models(for: "fx").map(\.id),
                       "A bot with no profile uses the Default login's list")
        XCTAssertEqual(runtime.models(for: "fx", profile: HarnessProfileStore.defaultID(.fx)).map(\.id), runtime.models(for: "fx").map(\.id))

        // Another team, read again after the switch, offers its own models.
        team = ["anthropic/claude-opus-5.5"]
        runtime.refreshFxModels(profile: work.id)
        try await waitUntil { runtime.fxProfileModels[work.id]?.first?.id == "anthropic/claude-opus-5.5" }

        // A login FX cannot read offers nothing rather than another team's models.
        runtime.loadFxProfileModels = { _, _ in throw HarnessSetupError("Not signed in") }
        runtime.refreshFxModels(profile: work.id)
        try await waitUntil { runtime.fxProfileModels[work.id]?.isEmpty == true }
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
}
