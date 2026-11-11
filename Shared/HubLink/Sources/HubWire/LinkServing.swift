import Foundation

/// What both ends of the link keep to, whichever QUIC carries it.
public enum LinkLimits {
    public static let alpn = "noodle-hub/1"
    /// What the Hub reads from a device; files travel in pieces well under it.
    public static let request = 1 << 20
    /// How often an open stream the Hub pushes down says something, if only an empty frame.
    public static let keepAlive: TimeInterval = 10
    /// How long a stream the Hub ended waits for the device to end its side.
    public static let closeGrace: TimeInterval = 5
    /// How long a connection may carry nothing before it is gone.
    public static let idleTimeout: TimeInterval = 30
}

/// An open stream the Hub pushes frames down until either side closes it.
public protocol LinkServerStream: AnyObject, Sendable {
    /// The device that opened it.
    var peer: LinkPublicKey { get }
    var isClosed: Bool { get }
    /// What was sent and has not left yet.
    var pendingBytes: Int { get }
    /// Frames the device sends up the stream.
    func onFrame(_ handler: @escaping @Sendable (Data) -> Void)
    func onClose(_ handler: @escaping @Sendable () -> Void)
    func send(_ payload: Data)
    func close()
}

/// What the Hub does with a request: answer it once, or keep the stream open to push frames.
public enum LinkReply: Sendable {
    case response(Data)
    case stream(@Sendable (any LinkServerStream) -> Void)
}

/// Where the Hub takes devices' requests, admitting only the keys `admits` lets in.
public protocol LinkListening: AnyObject, Sendable {
    /// Returns once the port is open.
    func start() async throws
    /// The port it took, once open.
    var port: UInt16? { get }
    func stop()
    /// Ends the open streams of keys no longer admitted.
    func disconnectRefused()
}

/// Opens a listener with the Hub's identity on `port`, which hands each admitted request to `handler`.
public typealias LinkListen = @Sendable (_ identity: LinkIdentity, _ port: UInt16,
                                         _ admits: @escaping @Sendable (LinkPublicKey) -> Bool,
                                         _ handler: @escaping @Sendable (LinkPublicKey, Data) async -> LinkReply) throws -> any LinkListening

extension LinkEndpoint {
    /// Posted when a name for this machine turns up after its addresses were read without it.
    public static let localNamesChanged = Notification.Name("HubLink.localNamesChanged")
}
