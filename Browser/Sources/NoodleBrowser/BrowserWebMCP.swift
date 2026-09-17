import BrowserBridge
import Foundation
import WebKit

/// The page runtime exposes website tools only. It has no native message handler,
/// filesystem access, agent credentials, or way to invoke the Browser broker.
@MainActor enum BrowserWebMCP {
    static let source: String = {
        guard let url = Bundle.module.url(forResource: "Resources", withExtension: nil)?.appendingPathComponent("WebMCP.js"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            preconditionFailure("Missing bundled WebMCP runtime")
        }
        return source
    }()

    static func install(into controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart,
            forMainFrameOnly: false, in: .page))
    }

    /// WebKit does not yet enforce the draft `tools` policy. Honor explicit
    /// response opt-outs at our native discovery/execution boundary as well.
    static func permits(_ response: URLResponse) -> Bool {
        guard let response = response as? HTTPURLResponse else { return false }
        if response.value(forHTTPHeaderField: "Origin-Agent-Cluster")?.trimmingCharacters(in: .whitespaces) == "?0" { return false }
        guard let policy = response.value(forHTTPHeaderField: "Permissions-Policy") else { return true }
        for directive in policy.split(separator: ",") {
            let parts = directive.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            guard parts.first?.lowercased() == "tools" else { continue }
            guard parts.count == 2 else { return false }
            if parts[1] == "*" { continue }
            guard parts[1].hasPrefix("("), parts[1].hasSuffix(")") else { return false }
            let origins = parts[1].dropFirst().dropLast().split(whereSeparator: \.isWhitespace)
            if origins.contains("self") { continue }
            guard let url = response.url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let scheme = components.scheme, let host = components.host else { return false }
            let defaultPort = (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80)
            let origin = "\(scheme)://\(host)" + (defaultPort ? "" : components.port.map { ":\($0)" } ?? "")
            if !origins.contains(Substring("\"" + origin + "\"")) { return false }
        }
        return true
    }
}

extension BrowserTab {
    func webMCP(_ request: BrowserRequest) async throws -> String {
        let frame = request.frame ?? "main"
        guard webMCPAllowed, frame == "main" || frames[frame] != nil else {
            throw BrowserError("WebMCP is disabled by this document's policy, or the frame is no longer available.")
        }
        if let info = frames[frame], let url = info.request.url {
            guard webMCPFramePolicies[url.absoluteString.components(separatedBy: "#")[0]] != false else {
                throw BrowserError("WebMCP is disabled by the frame's response policy.")
            }
        }
        let source = """
            const bridge = globalThis.__noodleWebMCP;
            if (!bridge) throw Error('WebMCP runtime unavailable in this document. Reload and inspect the tab.');
            const result = await bridge[operation](toolID, argumentsJSON);
            result.frame = frameID;
            const text = JSON.stringify(result);
            if (new TextEncoder().encode(text).length > 1048576) throw Error('WebMCP result exceeds 1 MiB. The action may have completed; do not retry automatically.');
            return text;
            """
        do {
            guard let text = try await evaluate(source, arguments: [
                "operation": request.operation == .webMCPList ? "list" : "call",
                "toolID": request.toolID ?? "", "argumentsJSON": request.arguments ?? "{}", "frameID": frame
            ], frame: frame, world: .page) as? String else { throw BrowserError("Invalid WebMCP response.") }
            return text
        } catch {
            if request.operation == .webMCPCall {
                throw BrowserError("WebMCP call interrupted: \(error.localizedDescription) The action may have run. Inspect the tab before retrying.")
            }
            throw error
        }
    }
}
