import Foundation

/// What to suggest when no address of a Hub answers, from the Hub's addresses and what the
/// device found out about its own connection.
public enum HubTroubleshooting {
    public struct Device: Equatable, Sendable {
        public var isOnline: Bool
        public var isOnWiFi: Bool
        public var isOnTailnet: Bool
        /// The system kept this app off the local network.
        public var isLocalNetworkDenied: Bool

        public init(isOnline: Bool, isOnWiFi: Bool, isOnTailnet: Bool, isLocalNetworkDenied: Bool) {
            self.isOnline = isOnline
            self.isOnWiFi = isOnWiFi
            self.isOnTailnet = isOnTailnet
            self.isLocalNetworkDenied = isLocalNetworkDenied
        }
    }

    public enum Advice: Equatable, Sendable {
        case goOnline, allowLocalNetwork, joinSameWiFi, connectTailscale, wakeHubMac, tryAgain
    }

    /// The most likely fix first. A Hub answering now, or being offline, makes the rest moot.
    /// `answered` are the endpoints that reached the Hub when tried one by one.
    public static func advice(for endpoints: [LinkEndpoint], on device: Device, answered: [LinkEndpoint] = []) -> [Advice] {
        guard answered.isEmpty else { return [.tryAgain] }
        guard device.isOnline else { return [.goOnline] }
        let networks = Set(endpoints.map(\.network))
        let throughTailnet = device.isOnTailnet && networks.contains(.tailnet)
        var advice: [Advice] = []
        if device.isLocalNetworkDenied { advice.append(.allowLocalNetwork) }
        if networks.contains(.home), !throughTailnet { advice.append(.joinSameWiFi) }
        if networks.contains(.tailnet), !device.isOnTailnet { advice.append(.connectTailscale) }
        advice.append(.wakeHubMac)
        return advice
    }
}
