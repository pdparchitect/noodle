import Darwin
import Foundation

/// A temporary, authenticated loopback server. Probing never creates a session,
/// talks to a shared background service, or exposes provider credentials to Noodle.
final class OpenCodeModelProbe: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let process = Process(), input = Pipe(), output = Pipe()
    private let waitsForCatalogueRefresh: Bool
    private let ready = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var address: String?
    private let password = UUID().uuidString + UUID().uuidString
    private var endpoint: URL!
    private var session: URLSession!
    private lazy var reader = JSONLineReader { [weak self] object in
        guard let self, let address = object["url"] as? String else { return }
        self.lock.lock(); defer { self.lock.unlock() }
        guard self.address == nil else { return }
        self.address = address
        self.ready.signal()
    }

    init(executable: URL, workspace: URL, environment: [String: String], profile: String) throws {
        waitsForCatalogueRefresh = !["true", "1"].contains(environment["OPENCODE_DISABLE_MODELS_FETCH"] ?? "")
            && environment["OPENCODE_MODELS_PATH"] == nil
        super.init()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", profile, executable.path, "serve", "--stdio", "--port", "0", "--hostname", "127.0.0.1"]
        process.currentDirectoryURL = workspace
        process.environment = environment.merging(["OPENCODE_PASSWORD": password]) { _, new in new }
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let reader = reader, ready = ready, finished = finished
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { reader.receive(data) }
        }
        process.terminationHandler = { _ in ready.signal(); finished.signal() }
        do {
            try process.run()
            try? input.fileHandleForReading.close(); try? output.fileHandleForWriting.close()
            guard ready.wait(timeout: .now() + 20) == .success else { throw failure() }
            lock.lock(); let address = address; lock.unlock()
            guard let address, let url = URL(string: address), url.scheme == "http", url.host == "127.0.0.1",
                  let port = url.port, (1...65535).contains(port), url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else { throw failure() }
            endpoint = url
            let configuration = URLSessionConfiguration.ephemeral
            configuration.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0]
            configuration.timeoutIntervalForRequest = 5
            configuration.timeoutIntervalForResource = 5
            session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        } catch { stop(); throw error }
    }

    func models() throws -> [HarnessModel] {
        try Self.loadModels(waitForRefresh: waitsForCatalogueRefresh, read: get)
    }

    static func loadModels(waitForRefresh: Bool, read: (String) throws -> Data,
                           now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                           sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws -> [HarnessModel] {
        // V2 starts with its bundled snapshot and refreshes models.dev in the
        // background with a ten-second request timeout. A nonempty (or briefly
        // unchanged) list is not readiness: it may still omit newly added models.
        // Allow the full fetch window plus provider reload time. An offline
        // refresh retains the latest usable snapshot; file-backed fixtures do
        // not need the network window. Keep this process alive throughout.
        let deadline = now() + OpenCodeProtocol.catalogueRefreshWindow
        while true {
            let data = try read("/api/model")
            let models = try OpenCodeProtocol.models(from: data)
            let remaining = deadline - now()
            if remaining <= 0 || (!waitForRefresh && !models.isEmpty) {
                guard !models.isEmpty else { return [] }
                let preferred = try read("/api/model/default")
                let envelope = try JSONSerialization.jsonObject(with: preferred) as? [String: Any]
                let model = envelope?["data"] as? [String: Any]
                let identifier = (model?["providerID"] as? String).flatMap { provider in
                    (model?["id"] as? String).map { provider + "/" + $0 }
                }
                return try OpenCodeProtocol.models(from: data, defaultIdentifier: identifier)
            }
            sleep(min(0.25, remaining))
        }
    }

    func get(_ path: String) throws -> Data {
        var request = URLRequest(url: endpoint.appendingPathComponent(String(path.dropFirst())))
        request.setValue("Basic " + Data("opencode:\(password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        let completed = DispatchSemaphore(value: 0)
        let result = Response()
        let task = session.dataTask(with: request) { data, response, error in
            if error == nil, (response as? HTTPURLResponse)?.statusCode == 200, let data, data.count <= 4_194_304 {
                result.data = data
            }
            completed.signal()
        }
        task.resume()
        guard completed.wait(timeout: .now() + 6) == .success, let data = result.data else {
            task.cancel(); throw failure()
        }
        return data
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func stop() {
        session?.invalidateAndCancel()
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close()
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        if finished.wait(timeout: .now() + 2) != .success {
            let target = getpgid(pid) == pid ? -pid : pid
            kill(target, SIGTERM)
            if finished.wait(timeout: .now() + 1) != .success {
                kill(target, SIGKILL)
                _ = finished.wait(timeout: .now() + 1)
            }
        }
    }

    private func failure() -> HarnessSetupError {
        HarnessSetupError("OpenCode’s private model inspection failed. Check its v2 installation and sign-in, then retry.")
    }

    private final class Response: @unchecked Sendable { var data: Data? }
}
