import Darwin
import Foundation
import NoodletFormat

/// Per-noodlet HTTP requests, independent of browser CORS and browser credentials. The public web
/// is open to every noodlet; this device and the network it is on only with `localNetwork`.
@MainActor public final class WebNetwork {
  /// The largest request body.
  public static let limit = 16 * 1_048_576
  /// The largest response, which waits in a file until the page reads it.
  public nonisolated static let responseLimit = 1 << 30
  private var requests: [String: Task<[String: Any], Error>] = [:]
  private let localNetwork: Bool
  static let localRefusal = "This noodlet reaches only the public web. To reach this device or its network, declare the local-network permission."

  /// `localNetwork` is whether the person allowed the noodlet the local network; without it,
  /// requests and the redirects they follow keep to public addresses.
  public init(localNetwork: Bool = false) { self.localNetwork = localNetwork }
  public func cancel(_ id: String) { requests[id]?.cancel() }
  public func stop() {
    for task in requests.values { task.cancel() }
    requests.removeAll()
  }
  public func fetch(_ body: [String: Any]) async throws -> [String: Any] {
    guard let id = body["id"] as? String, id.count <= 100,
      requests[id] == nil, requests.count < 8
    else { throw AppletError("A noodlet supports up to eight concurrent web requests.") }
    let request = try Self.request(body)
    let mode = body["redirect"] as? String ?? "follow"
    guard ["follow", "error", "manual"].contains(mode) else {
      throw AppletError("Invalid redirect mode.")
    }
    if !localNetwork, let host = request.url?.host {
      switch await Task.detached(operation: { Self.isPublic(host: host) }).value {
      case true?: break
      case false?: throw AppletError(Self.localRefusal)
      case nil: throw AppletError("Could not find \(host.prefix(100)).")
      }
    }
    let localNetwork = localNetwork
    let task = Task { try await Self.perform(request, redirect: mode, localNetwork: localNetwork) }
    requests[id] = task
    defer { requests.removeValue(forKey: id) }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
  public static func request(_ body: [String: Any]) throws -> URLRequest {
    guard let address = body["url"] as? String, address.utf8.count <= 8192,
      let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
      url.host != nil, url.user == nil, url.password == nil
    else {
      throw AppletError("Web requests require an HTTP or HTTPS URL without embedded credentials.")
    }
    let method = (body["method"] as? String ?? "GET").uppercased()
    guard !method.isEmpty, method.count <= 32,
      method.utf8.allSatisfy({ $0 >= 65 && $0 <= 90 }),
      !["CONNECT", "TRACE", "TRACK"].contains(method)
    else { throw AppletError("Unsupported HTTP method.") }
    var request = URLRequest(url: url, timeoutInterval: 60)
    request.httpMethod = method
    request.httpShouldHandleCookies = false
    if let headers = body["headers"] as? [String: String] {
      guard headers.count <= 100,
        headers.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 65536
      else { throw AppletError("Request headers exceed 64 KiB.") }
      for (key, value) in headers {
        guard !key.isEmpty, !key.contains(where: { $0.isWhitespace || $0 == ":" }),
          !key.utf8.contains(13), !key.utf8.contains(10), !value.utf8.contains(13), !value.utf8.contains(10), !value.utf8.contains(0)
        else { throw AppletError("Invalid HTTP header.") }
        // URLSession supplies framing; the caller may explicitly supply API credentials.
        if !["host", "content-length", "connection", "transfer-encoding"].contains(key.lowercased())
        {
          request.setValue(value, forHTTPHeaderField: key)
        }
      }
    }
    if let encoded = body["body"] as? String {
      guard encoded.utf8.count <= (limit + 2) / 3 * 4,
        let bytes = Data(base64Encoded: encoded), bytes.count <= limit,
        !["GET", "HEAD"].contains(method)
      else {
        throw AppletError("Request body must fit in 16 MiB and cannot be used with GET or HEAD.")
      }
      request.httpBody = bytes
    }
    return request
  }
  /// Whether every address `host` names is on the public internet, or nil when it names none.
  /// The connection resolves it again, so a name that changes its answer in between still gets
  /// through; this keeps out plain local addresses and names for them.
  nonisolated static func isPublic(host: String) -> Bool? {
    var hints = addrinfo()
    hints.ai_socktype = SOCK_STREAM
    var list: UnsafeMutablePointer<addrinfo>?
    let name = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    guard getaddrinfo(name, nil, &hints, &list) == 0, let list else { return nil }
    defer { freeaddrinfo(list) }
    var addresses: [String] = []
    for entry in sequence(first: list, next: { $0.pointee.ai_next }) {
      var text = [CChar](repeating: 0, count: Int(NI_MAXHOST))
      guard getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &text, socklen_t(text.count), nil, 0, NI_NUMERICHOST) == 0
      else { return nil }
      addresses.append(String(cString: text).split(separator: "%").first.map(String.init) ?? "")
    }
    return addresses.isEmpty ? nil : addresses.allSatisfy(isPublic(address:))
  }

  /// Whether a numeric address is on the public internet, not loopback, private, link-local,
  /// shared, multicast or reserved, including IPv4 carried inside IPv6.
  nonisolated static func isPublic(address: String) -> Bool {
    var v4 = in_addr(), v6 = in6_addr()
    if inet_pton(AF_INET, address, &v4) == 1 {
      return isPublic(v4: withUnsafeBytes(of: v4) { Array($0) })
    }
    guard inet_pton(AF_INET6, address, &v6) == 1 else { return false }
    let b = withUnsafeBytes(of: v6) { Array($0) }
    if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff { return isPublic(v4: Array(b[12...])) }
    if b[0..<12].allSatisfy({ $0 == 0 }) { return false }
    if b[0..<12] == [0, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0] { return isPublic(v4: Array(b[12...])) }
    if b[0] & 0xfe == 0xfc || b[0] == 0xff || (b[0] == 0xfe && b[1] & 0x80 == 0x80) { return false }
    return true
  }

  private nonisolated static func isPublic(v4 b: [UInt8]) -> Bool {
    switch (b[0], b[1], b[2]) {
    case (0, _, _), (10, _, _), (127, _, _), (169, 254, _), (192, 168, _), (192, 0, 0), (224...255, _, _): false
    case (100, 64...127, _), (172, 16...31, _), (198, 18...19, _): false
    default: true
    }
  }

  private static func perform(_ request: URLRequest, redirect: String, localNetwork: Bool) async throws -> [String: Any]
  {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForResource = 600
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("NoodletResponse-\(UUID().uuidString)")
    let download = ResponseFile(file, redirect: RedirectPolicy(mode: redirect, localNetwork: localNetwork))
    let response: HTTPURLResponse
    do {
      response = try await download.run(request, in: session)
    } catch {
      try? FileManager.default.removeItem(at: file)
      throw error
    }
    var headers: [String: String] = [:]
    for (key, value) in response.allHeaderFields {
      headers[String(describing: key)] = String(describing: value)
    }
    return [
      "url": response.url?.absoluteString ?? request.url!.absoluteString,
      "status": response.statusCode, "headers": headers, "file": file,
      "redirected": response.url != request.url,
    ]
  }
}

/// Writes a response's body to `file` as it arrives, refusing one larger than the limit.
final class ResponseFile: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let file: URL
  private let redirect: RedirectPolicy
  private let lock = NSLock()
  private var handle: FileHandle?
  private var written = 0
  private var response: HTTPURLResponse?
  private var failure: Error?
  private var done: CheckedContinuation<HTTPURLResponse, Error>?

  init(_ file: URL, redirect: RedirectPolicy) {
    self.file = file
    self.redirect = redirect
  }

  func run(_ request: URLRequest, in session: URLSession) async throws -> HTTPURLResponse {
    let task = session.dataTask(with: request)
    task.delegate = self
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        lock.withLock { done = continuation }
        task.resume()
      }
    } onCancel: { task.cancel() }
  }

  private func fail(_ message: String) -> URLSession.ResponseDisposition {
    lock.withLock { failure = AppletError(message) }
    return .cancel
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    redirect.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request,
                        completionHandler: completionHandler)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                  completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    guard let response = response as? HTTPURLResponse else {
      return completionHandler(fail("The server did not return an HTTP response."))
    }
    if redirect.mode == "error", (300..<400).contains(response.statusCode),
      response.value(forHTTPHeaderField: "Location") != nil
    {
      return completionHandler(fail("The server returned a redirect."))
    }
    guard response.expectedContentLength <= WebNetwork.responseLimit else {
      return completionHandler(fail("Response exceeds 1 GiB."))
    }
    guard FileManager.default.createFile(atPath: file.path, contents: nil),
      let handle = try? FileHandle(forWritingTo: file)
    else { return completionHandler(fail("The response could not be kept.")) }
    lock.withLock {
      self.response = response
      self.handle = handle
    }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let kept: Bool = lock.withLock {
      written += data.count
      guard written <= WebNetwork.responseLimit, (try? handle?.write(contentsOf: data)) != nil else { return false }
      return true
    }
    if !kept {
      lock.withLock { failure = failure ?? AppletError(written > WebNetwork.responseLimit ? "Response exceeds 1 GiB." : "The response could not be kept.") }
      dataTask.cancel()
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let (continuation, result): (CheckedContinuation<HTTPURLResponse, Error>?, Result<HTTPURLResponse, Error>) = lock.withLock {
      try? handle?.close()
      handle = nil
      let continuation = done
      done = nil
      if let failure { return (continuation, .failure(failure)) }
      if let error { return (continuation, .failure(error)) }
      guard let response else { return (continuation, .failure(AppletError("The server did not return an HTTP response."))) }
      return (continuation, .success(response))
    }
    continuation?.resume(with: result)
  }
}

final class RedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  let mode: String
  let localNetwork: Bool
  init(mode: String, localNetwork: Bool) {
    self.mode = mode
    self.localNetwork = localNetwork
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard mode == "follow", let url = request.url,
      ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil,
      url.password == nil, localNetwork || url.host.flatMap(WebNetwork.isPublic(host:)) == true
    else {
      completionHandler(nil)
      return
    }
    var next = request
    if url.host != response.url?.host || url.port != response.url?.port
      || url.scheme != response.url?.scheme
    {
      for header in ["Authorization", "Cookie", "Proxy-Authorization"] {
        next.setValue(nil, forHTTPHeaderField: header)
      }
    }
    completionHandler(next)
  }
}
