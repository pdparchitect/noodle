#if canImport(Network)
import Foundation
import Network

/// A siloed harness's only way out. The Agent Host runs one per session, outside the sandbox, on a loopback port
/// that the harness's profile names as its only reachable address. It answers HTTP CONNECT for the addresses on
/// the list and refuses everything else, including plain HTTP, before opening any connection. It also looks the
/// names up, so the harness needs no name service of its own. Only the name the client asks for is checked.
public final class HarnessEgressProxy: @unchecked Sendable {
    public private(set) var port: UInt16 = 0
    private let allowed: Set<String>
    private let report: @Sendable (String, Bool) -> Void
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Noodle.harness-egress")
    private var tunnels: [ObjectIdentifier: Tunnel] = [:]

    /// `allowed` holds lowercase `host:port` entries, where a star may stand for part of one name label, as in
    /// `*.openai.azure.com:443`. `report` hears every CONNECT address and whether it was allowed.
    public init(allowed: Set<String>, report: @escaping @Sendable (String, Bool) -> Void) throws {
        self.allowed = allowed
        self.report = report
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        let failure = Failure()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed(let error): failure.error = error; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, failure.error == nil, let port = listener.port?.rawValue else {
            listener.cancel()
            throw HarnessSetupError("The network proxy for this bot could not start.")
        }
        self.port = port
    }

    /// What tells a harness to use the proxy. Loopback stays direct: some harnesses talk to their own local server.
    public static func environment(port: UInt16) -> [String: String] {
        let address = "http://127.0.0.1:\(port)", direct = "localhost,127.0.0.1,::1"
        return ["HTTPS_PROXY": address, "https_proxy": address, "HTTP_PROXY": address, "http_proxy": address,
                "ALL_PROXY": address, "all_proxy": address, "NO_PROXY": direct, "no_proxy": direct,
                URLSessionRemoteTransport.siloProxyPortVariable: "\(port)"]
    }

    public func stop() {
        queue.sync {
            listener.cancel()
            tunnels.values.forEach { $0.close() }
            tunnels = [:]
        }
    }

    private func accept(_ client: NWConnection) {
        client.start(queue: queue)
        readRequest(client, buffered: Data())
    }

    /// Reads up to the end of the request's headers, which must fit in 16 KB.
    private func readRequest(_ client: NWConnection, buffered: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self else { return client.cancel() }
            var request = buffered
            if let data { request.append(data) }
            if let end = request.range(of: Data("\r\n\r\n".utf8)) {
                return self.open(client, head: request[..<end.lowerBound], rest: request[end.upperBound...])
            }
            guard error == nil, !complete, request.count < 16_384 else { return client.cancel() }
            self.readRequest(client, buffered: request)
        }
    }

    private func open(_ client: NWConnection, head: Data, rest: Data) {
        let line = String(decoding: head.prefix { $0 != 13 }, as: UTF8.self).split(separator: " ")
        guard line.count == 3, line[0] == "CONNECT", let address = Self.address(String(line[1])) else {
            return refuse(client)
        }
        guard Self.permits(address.text, allowed: allowed) else {
            report(address.text, false)
            return refuse(client)
        }
        report(address.text, true)
        let server = NWConnection(host: NWEndpoint.Host(address.host), port: NWEndpoint.Port(rawValue: address.port)!, using: .tcp)
        let tunnel = Tunnel(client: client, server: server) { [weak self] tunnel in
            self?.tunnels.removeValue(forKey: ObjectIdentifier(tunnel))
        }
        tunnels[ObjectIdentifier(tunnel)] = tunnel
        server.stateUpdateHandler = { state in
            switch state {
            case .ready:
                server.stateUpdateHandler = nil
                client.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                tunnel.start(pending: Data(rest))
            case .waiting, .failed:
                server.stateUpdateHandler = nil
                client.send(content: Data("HTTP/1.1 502 Bad Gateway\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                tunnel.close()
            default: break
            }
        }
        server.start(queue: queue)
    }

    private func refuse(_ client: NWConnection) {
        client.send(content: Data("HTTP/1.1 403 Forbidden\r\n\r\n".utf8), completion: .contentProcessed { _ in client.cancel() })
    }

    /// `host:port` with a port, lowercased; bracketed IPv6 literals are never on a list, so they are not parsed.
    static func address(_ text: String, pattern: Bool = false) -> (host: String, port: UInt16, text: String)? {
        guard let colon = text.lastIndex(of: ":"), let port = UInt16(text[text.index(after: colon)...]), port > 0 else { return nil }
        let host = text[..<colon].lowercased()
        guard !host.split(separator: ".", omittingEmptySubsequences: false).contains(where: \.isEmpty),
              host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || (pattern && $0 == "*") }) else { return nil }
        return (host, port, "\(host):\(port)")
    }

    /// Whether an address is on the list, exactly or by a pattern with the same number of labels.
    public static func permits(_ text: String, allowed: Set<String>) -> Bool {
        guard let address = address(text) else { return false }
        if allowed.contains(address.text) { return true }
        let labels = address.host.split(separator: ".")
        return allowed.contains { entry in
            guard entry.contains("*"), let pattern = Self.address(entry, pattern: true), pattern.port == address.port else { return false }
            let patterns = pattern.host.split(separator: ".")
            return patterns.count == labels.count && zip(patterns, labels).allSatisfy { pattern, label in
                guard let star = pattern.firstIndex(of: "*") else { return pattern == label }
                let prefix = pattern[..<star], suffix = pattern[pattern.index(after: star)...]
                return !suffix.contains("*") && label.count > prefix.count + suffix.count
                    && label.hasPrefix(prefix) && label.hasSuffix(suffix)
            }
        }
    }

    private final class Failure: @unchecked Sendable { var error: NWError? }
}

/// Copies bytes both ways until either side ends, then closes both.
private final class Tunnel: @unchecked Sendable {
    let client: NWConnection
    let server: NWConnection
    private let finished: (Tunnel) -> Void
    private var closed = false

    init(client: NWConnection, server: NWConnection, finished: @escaping (Tunnel) -> Void) {
        self.client = client
        self.server = server
        self.finished = finished
    }

    func start(pending: Data) {
        if !pending.isEmpty { server.send(content: pending, completion: .contentProcessed { _ in }) }
        pump(from: client, to: server)
        pump(from: server, to: client)
    }

    private func pump(from source: NWConnection, to destination: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    if error != nil { return self.close() }
                    if complete { return self.close() }
                    self.pump(from: source, to: destination)
                })
            } else if complete || error != nil {
                self.close()
            } else {
                self.pump(from: source, to: destination)
            }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        client.cancel()
        server.cancel()
        finished(self)
    }
}
#endif
