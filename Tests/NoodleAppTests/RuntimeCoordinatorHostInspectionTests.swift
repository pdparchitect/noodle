import Foundation
import NoodleCore
import XCTest
@testable import Noodle

@MainActor private final class HostInspectionFixture {
    var answers: [HarnessProvider: Result<HarnessHostInspection, Error>] = [:]
    var requests: [HarnessProvider] = []
    var cancelled: Set<HarnessProvider> = []
    /// Requests without an answer wait here, as a slow Agent Host would.
    var released = false

    func inspect(_ provider: HarnessProvider) async throws -> HarnessHostInspection {
        requests.append(provider)
        while answers[provider] == nil, !released {
            if Task.isCancelled { cancelled.insert(provider); throw CancellationError() }
            await Task.yield()
        }
        return try (answers[provider] ?? .failure(CancellationError())).get()
    }
}

@MainActor final class RuntimeCoordinatorHostInspectionTests: XCTestCase {
    private static let hostProviders: [HarnessProvider] = [.openCode, .grokBuild, .muse]

    private func fixture(_ host: HostInspectionFixture) throws -> RuntimeCoordinatorFixture {
        let f = try RuntimeCoordinatorFixture(inspectHost: { try await host.inspect($0) })
        addTeardownBlock { @MainActor in host.released = true; f.cleanUp() }
        return f
    }

    private func model(_ id: String) -> HarnessModel {
        HarnessModel(id: id, displayName: id, description: "", supportedEfforts: [], defaultEffort: "", isDefault: true)
    }

    /// OpenCode's report has no public initialiser; decode it as the Agent Host's reply is.
    private func openCode(_ executablePath: String?, authenticated: Bool, models: [HarnessModel] = []) throws -> OpenCodeInspectionResult {
        struct Reply: Encodable { let executablePath: String?; let authenticated: Bool; let models: [HarnessModel] }
        let data = try JSONEncoder().encode(Reply(executablePath: executablePath, authenticated: authenticated, models: models))
        return try JSONDecoder().decode(OpenCodeInspectionResult.self, from: data)
    }

    private func path(_ provider: HarnessProvider, in runtime: AgentRuntimeCoordinator) -> String? {
        runtime.installations.first { $0.provider == provider }?.executablePath
    }

    func testHostReportReplacesDiscoveredInstallationAndPublishesModels() async throws {
        let host = HostInspectionFixture(), f = try fixture(host)
        for provider in Self.hostProviders {
            host.answers[provider] = .success(.init(executablePath: "/host/\(provider.rawValue)",
                models: [model(provider.rawValue)], capabilityError: nil))
        }
        await f.runtime.refreshInstallations()
        XCTAssertEqual(host.requests, Self.hostProviders)
        for provider in Self.hostProviders {
            XCTAssertEqual(path(provider, in: f.runtime), "/host/\(provider.rawValue)")
            XCTAssertEqual(f.runtime.modelsByProvider[provider], [model(provider.rawValue)])
            XCTAssertNil(f.runtime.capabilityErrors[provider])
            XCTAssertNil(f.runtime.installationErrors[provider])
        }
    }

    func testCapabilityErrorIsShownForAnInstalledHarnessThatCannotBeUsed() async throws {
        let host = HostInspectionFixture(), f = try fixture(host)
        for provider in Self.hostProviders {
            host.answers[provider] = .success(.init(executablePath: "/host/\(provider.rawValue)", models: [],
                capabilityError: "Sign in to \(provider.rawValue)"))
        }
        await f.runtime.refreshInstallations()
        for provider in Self.hostProviders {
            XCTAssertEqual(f.runtime.capabilityErrors[provider], "Sign in to \(provider.rawValue)")
            XCTAssertNil(f.runtime.installationErrors[provider])
            XCTAssertEqual(f.runtime.modelsByProvider[provider], [])
        }
    }

    func testFailedInspectionIsReportedForThatHarnessOnlyAndClearsOnSuccess() async throws {
        for failing in Self.hostProviders {
            let host = HostInspectionFixture(), f = try fixture(host)
            for provider in Self.hostProviders {
                host.answers[provider] = .success(.init(executablePath: "/host/\(provider.rawValue)", models: [], capabilityError: nil))
            }
            let discovered = path(failing, in: f.runtime)
            host.answers[failing] = .failure(HarnessSetupError("Host unavailable"))
            await f.runtime.refreshInstallations()
            for provider in Self.hostProviders {
                XCTAssertEqual(f.runtime.installationErrors[provider], provider == failing ? "Host unavailable" : nil)
                XCTAssertEqual(f.runtime.capabilityErrors[provider], provider == failing ? "Host unavailable" : nil)
            }
            XCTAssertEqual(path(failing, in: f.runtime), discovered)

            host.answers[failing] = .success(.init(executablePath: "/host/repaired", models: [], capabilityError: nil))
            await f.runtime.refreshInstallations()
            XCTAssertNil(f.runtime.installationErrors[failing])
            XCTAssertNil(f.runtime.capabilityErrors[failing])
            XCTAssertEqual(path(failing, in: f.runtime), "/host/repaired")
        }
    }

    func testChangingOneHarnessForgetsOnlyItsHostReport() async throws {
        for changed in Self.hostProviders {
            let host = HostInspectionFixture(), f = try fixture(host)
            let discovered = path(changed, in: f.runtime)
            for provider in Self.hostProviders {
                host.answers[provider] = .success(.init(executablePath: "/host/\(provider.rawValue)", models: [], capabilityError: nil))
            }
            await f.runtime.refreshInstallations()
            XCTAssertEqual(f.runtime.refreshInstallation(changed).executablePath, discovered)
            // Rebuilding the catalogue must not bring the stale report back.
            f.runtime.refreshCapabilities()
            for provider in Self.hostProviders {
                XCTAssertEqual(path(provider, in: f.runtime), provider == changed ? discovered : "/host/\(provider.rawValue)")
            }
        }
    }

    func testStoppingCancelsEveryPendingHostInspection() async throws {
        let host = HostInspectionFixture(), f = try fixture(host)
        f.runtime.refreshCapabilities()
        try await f.clock.waitUntil { Set(host.requests) == Set(Self.hostProviders) }
        f.runtime.stopAll()
        try await f.clock.waitUntil { host.cancelled == Set(Self.hostProviders) }
    }

    func testCapabilityErrorsDescribeEachHarness() throws {
        XCTAssertEqual(HarnessHostInspection(GrokInspectionResult(executablePath: nil, authenticated: false, models: [])).capabilityError,
            "Grok Build is not installed")
        XCTAssertEqual(HarnessHostInspection(GrokInspectionResult(executablePath: "/grok", authenticated: false, models: [])).capabilityError,
            "Sign in to Grok Build in Settings → Harness.")
        XCTAssertNil(HarnessHostInspection(GrokInspectionResult(executablePath: "/grok", authenticated: true, models: [])).capabilityError)

        XCTAssertEqual(HarnessHostInspection(try openCode(nil, authenticated: true)).capabilityError,
            "OpenCode is not installed")
        XCTAssertEqual(HarnessHostInspection(try openCode("/opencode", authenticated: false)).capabilityError,
            "Run opencode auth login in Terminal, then check again.")
        XCTAssertNil(HarnessHostInspection(try openCode("/opencode", authenticated: false, models: [model("free")])).capabilityError)
        XCTAssertNil(HarnessHostInspection(try openCode("/opencode", authenticated: true)).capabilityError)

        XCTAssertEqual(HarnessHostInspection(MuseInspectionResult(executablePath: nil, models: [])).capabilityError, "Muse Code is not installed")
        XCTAssertNil(HarnessHostInspection(MuseInspectionResult(executablePath: "/muse", models: [])).capabilityError)
    }
}
