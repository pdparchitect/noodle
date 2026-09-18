import AppKit
import Foundation
import Network

enum ComputerStartupRecovery: Error, LocalizedError, Equatable {
    case localNetwork

    var title: String { "Allow Local Network access" }
    private var instructions: String {
        "macOS is blocking the connection to this computer’s desktop. In System Settings → Privacy & Security → Local Network, enable \(ComputerAppIdentity.name), then choose Try Again."
    }
    var errorDescription: String? { instructions }
    var explanation: String {
        "The desktop runs on this Mac, but macOS treats its virtual network as a local network. " + instructions
    }

    @MainActor func openSettings(open: (URL) -> Bool = { NSWorkspace.shared.open($0) }) -> Bool {
        if open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!) { return true }
        return open(URL(string: "x-apple.systempreferences:com.apple.preference.security")!)
    }
}

/// Diagnose the actual guest endpoint. A general path monitor can report that
/// Wi-Fi works even while local-network privacy blocks this particular address.
protocol LocalNetworkProbeConnection: AnyObject, Sendable {
    func start(on queue: DispatchQueue, report: @escaping @Sendable (Bool) -> Void)
    func cancel()
}

private final class NativeLocalNetworkProbeConnection: LocalNetworkProbeConnection, @unchecked Sendable {
    let connection: NWConnection
    init(host: String, port: NWEndpoint.Port) {
        connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
    }
    func start(on queue: DispatchQueue, report: @escaping @Sendable (Bool) -> Void) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .waiting, .failed:
                if self.connection.currentPath?.unsatisfiedReason == .localNetworkDenied { report(true) }
                else if case .failed = state { report(false) }
            case .ready, .cancelled: report(false)
            default: break
            }
        }
        connection.start(queue: queue)
    }
    func cancel() { connection.stateUpdateHandler = nil; connection.cancel() }
}

final class LocalNetworkAccessProbe: @unchecked Sendable {
    private let connection: any LocalNetworkProbeConnection
    private let timeout: TimeInterval
    private let queue = DispatchQueue(label: "Computer.LocalNetworkAccess")
    // Accessed only on queue, including cancellation and the timeout.
    private var continuations: [CheckedContinuation<Bool, Never>] = []
    private var result: Bool?
    private var deadline: DispatchWorkItem?

    init(connection: any LocalNetworkProbeConnection, timeout: TimeInterval = 2) {
        self.connection = connection; self.timeout = timeout
    }

    static func isDenied(for url: URL) async -> Bool {
        guard let host = url.host, let port = NWEndpoint.Port(rawValue: UInt16(exactly: url.port ?? 443) ?? 0), port.rawValue != 0 else { return false }
        let probe = LocalNetworkAccessProbe(connection: NativeLocalNetworkProbeConnection(host: host, port: port))
        return await probe.check()
    }

    func check() async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [self] in
                    if let result = self.result { continuation.resume(returning: result); return }
                    self.continuations.append(continuation)
                    guard self.continuations.count == 1 else { return }
                    self.connection.start(on: self.queue) { [weak self] denied in
                        guard let self else { return }
                        self.queue.async { self.finish(denied) }
                    }
                    let deadline = DispatchWorkItem { [weak self] in self?.finish(false) }
                    self.deadline = deadline
                    self.queue.asyncAfter(deadline: .now() + self.timeout, execute: deadline)
                }
            }
        } onCancel: {
            self.queue.async { self.finish(false) }
        }
    }

    private func finish(_ denied: Bool) {
        guard result == nil else { return }
        result = denied
        deadline?.cancel(); deadline = nil
        connection.cancel()
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting { continuation.resume(returning: denied) }
    }
}
