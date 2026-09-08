import Foundation

/// Last confirmed Settings presentation only. Never use this cache to launch a harness
/// or authorize access. It contains no credentials, account details or sign-in codes.
public struct HarnessPresentationSnapshot: Codable, Equatable, Sendable {
    public let installation: HarnessInstallation
    public let authentication: HarnessAuthenticationStatus?
    public let version: HarnessVersionReport?

    public init(installation: HarnessInstallation, authentication: HarnessAuthenticationStatus?, version: HarnessVersionReport? = nil) {
        self.installation = installation
        self.authentication = installation.isAvailable ? authentication : nil
        self.version = installation.isAvailable ? version : nil
    }
}

public enum HarnessPresentationCache {
    public static let defaultsKey = "Noodle.harnessPresentation.v1"

    public static func load(from defaults: UserDefaults) -> [HarnessProvider: HarnessPresentationSnapshot] {
        guard let data = defaults.data(forKey: defaultsKey),
              let snapshots = try? JSONDecoder().decode([HarnessPresentationSnapshot].self, from: data) else { return [:] }
        return snapshots.reduce(into: [:]) { result, snapshot in
            result[snapshot.installation.provider] = HarnessPresentationSnapshot(
                installation: snapshot.installation, authentication: snapshot.authentication, version: snapshot.version)
        }
    }

    public static func save(_ snapshots: [HarnessProvider: HarnessPresentationSnapshot], to defaults: UserDefaults) {
        let ordered = HarnessProvider.allCases.compactMap { snapshots[$0] }
        guard let data = try? JSONEncoder().encode(ordered), defaults.data(forKey: defaultsKey) != data else { return }
        defaults.set(data, forKey: defaultsKey)
    }
}
