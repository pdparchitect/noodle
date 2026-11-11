import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import NoodleCore

/// Retains the HTTP status across URLSession without exposing response contents.
struct MCPHTTPError: Error, CustomNSError, Sendable {
    let status: Int
    static var errorDomain: String { "Noodle.MCP.HTTP" }
    var errorCode: Int { status }
}

/// Supplies the SDK's HTTP transport with a no-redirect, bounded data loader.
/// In particular, bearer credentials must never follow a server redirect.
final class MCPGuardedHTTP: URLProtocol, URLSessionDataDelegate, @unchecked Sendable {
    private var session: URLSession?
    private var loadingTask: URLSessionDataTask?
    private var received = 0
    #if canImport(FoundationNetworking)
    /// Linux's URLSession keeps only the last piece a protocol of its own hands over, so there the response
    /// is held here and handed over whole once it has all come. On a Mac it streams, as event streams need.
    private var pending = Data()
    #endif
    /// Why the response is refused. Kept here rather than left to cancelling: Linux's URLSession can go on
    /// delivering after a cancel, and nothing refused may reach the client.
    private var refusal: Error?
    // Per-instance configuration lets transport tests run without shared session state.
    var sessionConfiguration: () -> URLSessionConfiguration = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = []
        return configuration
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, (try? MCPConnectionRecord.validatedEndpoint(url)) != nil else {
            client?.urlProtocol(self, didFailWithError: MCPServiceError.invalidMetadata)
            return
        }
        let configuration = sessionConfiguration()
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 90
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        loadingTask = session.dataTask(with: request)
        loadingTask?.resume()
    }
    override func stopLoading() { loadingTask?.cancel(); session?.invalidateAndCancel() }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, !(300..<400).contains(response.statusCode),
              response.expectedContentLength <= 8 * 1_048_576 else {
            refusal = URLError(.cancelled)
            completionHandler(.cancel)
            return
        }
        guard (200..<300).contains(response.statusCode) else {
            refusal = MCPHTTPError(status: response.statusCode)
            completionHandler(.cancel)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard refusal == nil else { return }
        received += data.count
        guard received <= 8 * 1_048_576 else {
            refusal = URLError(.cancelled)
            loadingTask?.cancel()
            return
        }
        #if canImport(FoundationNetworking)
        pending.append(data)
        #else
        client?.urlProtocol(self, didLoad: data)
        #endif
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let refusal { client?.urlProtocol(self, didFailWithError: refusal) }
        else if let error { client?.urlProtocol(self, didFailWithError: error) }
        else {
            #if canImport(FoundationNetworking)
            if !pending.isEmpty { client?.urlProtocol(self, didLoad: pending) }
            pending = Data()
            #endif
            client?.urlProtocolDidFinishLoading(self)
        }
        session.finishTasksAndInvalidate()
        self.session = nil
        self.loadingTask = nil
    }
}
