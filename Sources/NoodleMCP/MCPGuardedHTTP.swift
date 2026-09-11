import Foundation
import NoodleCore

/// Supplies the SDK's HTTP transport with a no-redirect, bounded data loader.
/// In particular, bearer credentials must never follow a server redirect.
final class MCPGuardedHTTP: URLProtocol, URLSessionDataDelegate, @unchecked Sendable {
    private var session: URLSession?
    private var loadingTask: URLSessionDataTask?
    private var received = 0
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
            completionHandler(.cancel)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        received += data.count
        guard received <= 8 * 1_048_576 else {
            loadingTask?.cancel()
            return
        }
        client?.urlProtocol(self, didLoad: data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { client?.urlProtocol(self, didFailWithError: error) }
        else { client?.urlProtocolDidFinishLoading(self) }
        session.finishTasksAndInvalidate()
        self.session = nil
        self.loadingTask = nil
    }
}
