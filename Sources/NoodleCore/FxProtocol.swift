import Foundation

/// FX v0.0.8 uses ACP JSON-RPC over newline-delimited stdio.
public enum FxProtocol {
    public static var initializeParameters: [String: Any] {
        ["protocolVersion": 1,
         "clientInfo": ["name": "noodle", "title": "Noodle", "version": "1"],
         "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false]]
    }
    /// FX owns native tools; no client filesystem/terminal service is exposed.
    /// A held safety review is a failed action, not a successfully handled wake.
    public static func reviewWasHeld(_ update: [String: Any]) -> Bool {
        guard update["sessionUpdate"] as? String == "tool_call_update",
              update["status"] as? String == "failed",
              let contents = update["content"] as? [[String: Any]] else { return false }
        return contents.contains { item in
            guard let content = item["content"] as? [String: Any],
                  let text = content["text"] as? String,
                  let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let error = object["error"] as? [String: Any] else { return false }
            return error["type"] as? String == "tool_review_held" && error["held"] as? Bool == true
        }
    }
    public static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && !value.hasPrefix("-") &&
        value.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    public static func models(from data: Data, defaultModel: String?) throws -> [HarnessModel] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["kind"] as? String == "models", let ids = object["ids"] as? [String] else {
            throw HarnessSetupError("FX returned an unsupported model catalogue.")
        }
        var seen: Set<String> = []
        return ids.filter { validIdentifier($0) && seen.insert($0).inserted }.map {
            HarnessModel(id: $0, displayName: $0, description: "Available through your FX provider.", supportedEfforts: [], defaultEffort: "", isDefault: $0 == defaultModel)
        }
    }

    public static func permissionResponse(params: [String: Any], sessionID: String?, extendedAccess: Bool) -> [String: Any] {
        guard extendedAccess, let sessionID, params["sessionId"] as? String == sessionID,
              let options = params["options"] as? [[String: Any]],
              let option = options.first(where: { $0["kind"] as? String == "allow_once" }),
              let id = option["optionId"] as? String, !id.isEmpty else {
            return ["outcome": ["outcome": "cancelled"]]
        }
        return ["outcome": ["outcome": "selected", "optionId": id]]
    }

    public static func loginChallenge(_ text: String) -> HarnessSignInChallenge? {
        // A streaming read can end midway through a device code.
        let lines = Array(text.components(separatedBy: .newlines).dropLast())
        guard let raw = lines.first(where: { $0.hasPrefix("Open https://") }).map({ String($0.dropFirst(5)) }),
              let url = URL(string: raw), url.scheme == "https", url.host == "vercel.com",
              url.user == nil, url.password == nil, url.port == nil,
              let code = lines.first(where: { $0.hasPrefix("Code: ") }).map({ String($0.dropFirst(6)) }),
              !code.isEmpty, code.count <= 64 else { return nil }
        return HarnessSignInChallenge(url: url, code: code)
    }
}
