import Foundation
import Observation
import NoodleCore

public enum FxSetupProvider {
    public static let installationGuide = HarnessInstallationGuide(command: "curl -fsSL https://fx.sh/setup.sh | bash",
        instructions: "Run Vercel’s official FX installer in Terminal, then check the installation here and sign in with Vercel. Noodle keeps its own sign-in, separate from the one fx uses in Terminal.",
        documentationURL: URL(string: "https://fx.sh/docs")!)
}

@MainActor
public enum FxModelProbe {
    /// Codex only when the app cannot run it itself: a copy Noodle installed.
    static func load(path: String, provider: HarnessProvider = .fx) async throws -> [HarnessModel] {
        try await AgentHostRequest().load(timeout: .seconds(65), noReply: "\(provider.displayName) returned no models.",
            timedOut: "\(provider.displayName) model discovery timed out.") {
            if provider == .codex { $0.codexModels(executablePath: path, reply: $1) }
            else { $0.fxModels(executablePath: path, reply: $1) }
        }
    }
}

/// The Vercel team each FX login sends model requests through, read and changed
/// with `fx teams` by the Agent Host, which resolves the login's folder.
@MainActor @Observable
public final class FxTeams {
    public private(set) var teams: [UUID: [FxTeam]] = [:]
    public private(set) var errors: [UUID: String] = [:]
    public private(set) var busy: Set<UUID> = []
    @ObservationIgnored private let request: @MainActor (UUID, String, String?) async throws -> [FxTeam]

    /// `request` lists a login's teams, selecting the given slug first; by default the Agent Host does.
    public init(request: (@MainActor (UUID, String, String?) async throws -> [FxTeam])? = nil) {
        self.request = request ?? { profile, path, slug in
            try await AgentHostRequest().load(timeout: .seconds(65), noReply: "FX returned no teams.",
                                              timedOut: "FX did not answer about its teams in time.") {
                $0.fxTeams(profile: profile, executablePath: path, selecting: slug, reply: $1)
            }
        }
    }

    public func load(_ profile: UUID, executablePath: String) async {
        guard !busy.contains(profile) else { return }
        await perform(profile, executablePath: executablePath, selecting: nil)
    }

    /// `then` runs once FX has switched, so the bots on the login can pick the team up.
    public func select(_ team: FxTeam, profile: UUID, executablePath: String,
                       then done: @escaping @MainActor () -> Void = {}) {
        guard !team.isSelected, !busy.contains(profile) else { return }
        Task {
            if await perform(profile, executablePath: executablePath, selecting: team.slug) { done() }
        }
    }

    public func forget(_ profile: UUID) {
        teams[profile] = nil
        errors[profile] = nil
    }

    @discardableResult
    private func perform(_ profile: UUID, executablePath: String, selecting slug: String?) async -> Bool {
        busy.insert(profile)
        defer { busy.remove(profile) }
        do {
            teams[profile] = try await request(profile, executablePath, slug)
            errors[profile] = nil
            return true
        } catch {
            if !(error is CancellationError) { errors[profile] = error.localizedDescription }
            return false
        }
    }
}
