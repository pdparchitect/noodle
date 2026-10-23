import Foundation

/// IMAP folder names outside ASCII travel in modified UTF-7 (RFC 3501, 5.1.3): "Odeslan&AOk-" is "Odeslané".
public enum MailFolderName {
    /// The readable name. Anything that isn't valid modified UTF-7 comes back unchanged.
    public static func display(_ raw: String) -> String {
        var result = ""
        var index = raw.startIndex
        while index < raw.endIndex {
            guard raw[index] == "&" else { result.append(raw[index]); index = raw.index(after: index); continue }
            guard let end = raw[index...].firstIndex(of: "-") else { return raw }
            let encoded = raw[raw.index(after: index)..<end]
            if encoded.isEmpty { result.append("&") }
            else {
                guard let decoded = decode(encoded) else { return raw }
                result.append(decoded)
            }
            index = raw.index(after: end)
        }
        return result
    }

    private static func decode(_ encoded: Substring) -> String? {
        guard encoded.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == ",") }) else { return nil }
        var base64 = encoded.replacingOccurrences(of: ",", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64), !data.isEmpty, data.count % 2 == 0 else { return nil }
        return String(data: data, encoding: .utf16BigEndian)
    }
}
