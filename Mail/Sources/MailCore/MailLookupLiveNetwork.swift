import dnssd
import Foundation

/// Find Servers' real network: HTTPS only, small answers, short timeouts, nothing stored, and MX through the system resolver.
public struct MailLookupLiveNetwork: MailLookupNetwork {
    /// Settings files are a few kilobytes; anything far bigger isn't one.
    static let maximumBytes = 256 * 1024
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    public init() {}

    public func fetch(_ url: URL) async -> MailFetch {
        guard Self.allowsRedirect(to: url) else { return .failed }
        var request = URLRequest(url: url)
        request.setValue("application/xml, text/xml", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await Self.session.bytes(for: request, delegate: HTTPSOnly())
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return .missing }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > Self.maximumBytes { return .missing }
            }
            return .data(data)
        } catch {
            return .failed
        }
    }

    public func mailExchangers(for domain: String) async -> [String]? {
        await withCheckedContinuation { continuation in
            MXQuery(domain: domain) { continuation.resume(returning: $0) }.start()
        }
    }

    static func allowsRedirect(to url: URL?) -> Bool { url?.scheme?.lowercased() == "https" }

    /// An MX record's data: a two-byte preference, then the host as length-prefixed labels ending in zero.
    /// Compression pointers (0xC0…) never appear in data the resolver hands over, so they are refused.
    static func exchanger(_ bytes: UnsafeRawBufferPointer) -> (preference: Int, host: String)? {
        guard bytes.count >= 3 else { return nil }
        var labels: [String] = [], index = 2
        while index < bytes.count {
            let length = Int(bytes[index]); index += 1
            if length == 0 {
                let host = labels.joined(separator: ".").lowercased()
                return MailAutoconfig.isHostName(host) ? (Int(bytes[0]) << 8 | Int(bytes[1]), host) : nil
            }
            guard length < 64, index + length <= bytes.count else { return nil }
            labels.append(String(decoding: bytes[index..<(index + length)], as: UTF8.self))
            index += length
        }
        return nil
    }

    /// Refuses a redirect away from HTTPS; the 3xx answer then counts as missing.
    private final class HTTPSOnly: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            MailLookupLiveNetwork.allowsRedirect(to: request.url) ? request : nil
        }
    }
}

/// One MX question to the system resolver. It answers once: the sorted hosts in the answer (none, if it held no usable
/// host), or nil when DNS failed or nothing came within 5 s. With flags 0 mDNSResponder never reports "no such record"
/// or "no such name", so a domain without MX ends as nil too.
private final class MXQuery: @unchecked Sendable {
    private let domain: String
    private let queue = DispatchQueue(label: "Noodle Mail MX lookup")
    private var reference: DNSServiceRef?
    private var records: [(preference: Int, host: String)] = []
    private var completion: (([String]?) -> Void)?
    private var retained: Unmanaged<MXQuery>?

    init(domain: String, completion: @escaping ([String]?) -> Void) {
        self.domain = domain
        self.completion = completion
    }

    func start() {
        queue.async { [self] in
            retained = Unmanaged.passRetained(self)
            var reference: DNSServiceRef?
            let status = DNSServiceQueryRecord(&reference, 0, 0, domain, UInt16(kDNSServiceType_MX), UInt16(kDNSServiceClass_IN),
                                               MXQuery.reply, retained?.toOpaque())
            guard status == kDNSServiceErr_NoError, let reference else { return finish(nil) }
            self.reference = reference
            DNSServiceSetDispatchQueue(reference, queue)
            queue.asyncAfter(deadline: .now() + 5) { [self] in finish(records.isEmpty ? nil : sorted()) }
        }
    }

    private static let reply: DNSServiceQueryRecordReply = { _, flags, _, error, _, _, _, length, data, _, context in
        guard let context else { return }
        Unmanaged<MXQuery>.fromOpaque(context).takeUnretainedValue().receive(flags: flags, error: error, data: data, length: Int(length))
    }

    /// Runs on `queue`, where DNSServiceSetDispatchQueue delivers replies.
    private func receive(flags: DNSServiceFlags, error: DNSServiceErrorType, data: UnsafeRawPointer?, length: Int) {
        guard error == kDNSServiceErr_NoError else { return finish(records.isEmpty ? nil : sorted()) }
        if flags & kDNSServiceFlagsAdd != 0, let data,
           let record = MailLookupLiveNetwork.exchanger(UnsafeRawBufferPointer(start: data, count: length)) {
            records.append(record)
        }
        if flags & kDNSServiceFlagsMoreComing == 0 { finish(sorted()) }
    }

    private func sorted() -> [String] { records.sorted { $0.preference < $1.preference }.map(\.host) }

    /// Answers once, then stops the query and lets go of itself.
    private func finish(_ hosts: [String]?) {
        guard let completion else { return }
        self.completion = nil
        if let reference { DNSServiceRefDeallocate(reference); self.reference = nil }
        completion(hosts)
        retained?.release(); retained = nil
    }
}
