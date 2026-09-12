import AppletBridge
import Foundation

/// Per-noodlet HTTP requests, independent of browser CORS and browser credentials.
@MainActor final class WebNetwork {
  static let limit = 16 * 1_048_576
  private var requests: [String: Task<[String: Any], Error>] = [:]

  func cancel(_ id: String) { requests[id]?.cancel() }
  func stop() {
    for task in requests.values { task.cancel() }
    requests.removeAll()
  }
  func fetch(_ body: [String: Any], enabled: Bool) async throws -> [String: Any] {
    guard enabled else {
      throw AppletError("Set network: true in noodlet.json to make web requests.")
    }
    guard let id = body["id"] as? String, id.count <= 100,
      requests[id] == nil, requests.count < 8
    else { throw AppletError("A noodlet supports up to eight concurrent web requests.") }
    let request = try Self.request(body)
    let mode = body["redirect"] as? String ?? "follow"
    guard ["follow", "error", "manual"].contains(mode) else {
      throw AppletError("Invalid redirect mode.")
    }
    let task = Task { try await Self.perform(request, redirect: mode) }
    requests[id] = task
    defer { requests.removeValue(forKey: id) }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
  static func request(_ body: [String: Any]) throws -> URLRequest {
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
  private static func perform(_ request: URLRequest, redirect: String) async throws -> [String: Any]
  {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForResource = 120
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let delegate = RedirectPolicy(mode: redirect)
    let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
    guard let response = response as? HTTPURLResponse else {
      throw AppletError("The server did not return an HTTP response.")
    }
    if redirect == "error", (300..<400).contains(response.statusCode),
      response.value(forHTTPHeaderField: "Location") != nil
    {
      throw AppletError("The server returned a redirect.")
    }
    guard response.expectedContentLength <= limit else {
      throw AppletError("Response exceeds 16 MiB.")
    }
    var data = Data()
    for try await byte in bytes {
      guard data.count < limit else { throw AppletError("Response exceeds 16 MiB.") }
      data.append(byte)
    }
    try Task.checkCancellation()
    var headers: [String: String] = [:]
    for (key, value) in response.allHeaderFields {
      headers[String(describing: key)] = String(describing: value)
    }
    return [
      "url": response.url?.absoluteString ?? request.url!.absoluteString,
      "status": response.statusCode, "headers": headers, "body": data.base64EncodedString(),
      "redirected": response.url != request.url,
    ]
  }
}

private final class RedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  let mode: String
  init(mode: String) { self.mode = mode }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard mode == "follow", let url = request.url,
      ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil,
      url.password == nil
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
